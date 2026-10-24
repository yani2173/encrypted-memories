#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require "tempfile"
require "tmpdir"
require_relative "app_store_connect"

# Compatibility shim for Ruby 2.6 (CI runs Ruby 3.x)
unless Array.method_defined?(:filter_map)
  class Array
    def filter_map(&block)
      map(&block).compact
    end
  end
end

class FakeAppStoreConnectClient
  attr_reader :calls

  def initialize(
    version_state: "PREPARE_FOR_SUBMISSION",
    release_type: "MANUAL",
    groups: nil,
    review_items: [],
    beta_phone: "+431234567",
    review_demo_account_required: true,
    review_demo_account_name: "reviewer@example.com",
    review_demo_account_password: "test-password",
    review_notes: "Sign in with the demo account and verify the tip screen.",
    app_bundle_identifier: "at.oncloud.encryptedmemories",
    in_app_purchase_state: "APPROVED",
    in_app_purchase_versions: nil,
    in_app_purchase_review_note: :contract,
    in_app_purchase_screenshot_state: "COMPLETE",
    in_app_purchase_description: "Editable App Store description.",
    in_app_purchase_prices: [{ "startDate" => nil, "endDate" => nil }],
    in_app_purchase_available_territories: %w[AUT USA],
    bundle_id_capabilities: ["IN_APP_PURCHASE"],
    app_store_versions_exist: true,
    app_store_localizations: nil,
    app_store_versions: nil,
    review_submissions: [],
    cancel_error_status: nil,
    cancel_transition_reads: 0,
    rename_error_status: nil,
    rename_mutates_before_error: false,
    localization_lock_conflicts: 0, # how many localization writes raise a 409 whatsNew lock
    localization_lock_codes: ["STATE_ERROR"], # error codes carried by simulated whatsNew lock errors
    localization_conflict_transitions_to_submitted: false, # whether the conflict also moves versions to WAITING_FOR_REVIEW
    public_link_error_status: nil # HTTP status (or :transport) that a public link change of a beta group raises
  )
    @version_state = version_state
    @release_type = release_type
    @groups = groups
    @review_items = review_items
    @beta_phone = beta_phone
    @review_demo_account_required = review_demo_account_required
    @review_demo_account_name = review_demo_account_name
    @review_demo_account_password = review_demo_account_password
    @review_notes = review_notes
    @app_bundle_identifier = app_bundle_identifier
    @in_app_purchase_state = in_app_purchase_state
    @in_app_purchase_versions = in_app_purchase_versions || [{ "version" => 1, "state" => "PREPARE_FOR_SUBMISSION" }]
    @in_app_purchase_review_note = in_app_purchase_review_note
    @in_app_purchase_screenshot_state = in_app_purchase_screenshot_state
    @in_app_purchase_description = in_app_purchase_description
    @in_app_purchase_prices = in_app_purchase_prices
    @in_app_purchase_available_territories = in_app_purchase_available_territories
    @bundle_id_capabilities = bundle_id_capabilities
    @app_store_versions_exist = app_store_versions_exist
    @created_app_store_versions = {}
    @configured_app_store_versions = app_store_versions&.transform_values do |versions|
      versions.map { |version| Marshal.load(Marshal.dump(version)) }
    end
    @known_app_store_versions = {}
    @review_submissions = review_submissions.map { |submission| Marshal.load(Marshal.dump(submission)) }
    @cancel_error_status = cancel_error_status
    @cancel_error_consumed = false
    @cancel_transition_reads = cancel_transition_reads
    @pending_cancellations = {}
    @rename_error_status = rename_error_status
    @rename_error_consumed = false
    @rename_mutates_before_error = rename_mutates_before_error
    @localization_lock_conflicts = localization_lock_conflicts
    @localization_lock_codes = localization_lock_codes
    @localization_conflict_transitions_to_submitted = localization_conflict_transitions_to_submitted
    @app_store_localizations = app_store_localizations
    @public_link_error_status = public_link_error_status
    @calls = []
  end

  def collection(path, query: {})
    @calls << [:collection, path, query]
    case path
    when "/v1/builds"
      platform = query.fetch("filter[preReleaseVersion.platform]")
      [build(platform)]
    when "/v1/apps/6805117080/betaGroups"
      @groups || [group("Internal Testers", true), group("External Testers", false)]
    when %r{\A/v1/betaGroups/.+/builds\z}
      []
    when "/v1/apps/6805117080/betaAppLocalizations"
      [{ "attributes" => { "locale" => "en-US", "description" => "A native photo library." } }]
    when "/v1/betaAppReviewDetails"
      [{
        "id" => "beta-review-details",
        "attributes" => {
          "contactFirstName" => "App",
          "contactLastName" => "Reviewer",
          "contactPhone" => @beta_phone,
          "contactEmail" => "review@example.com",
          "demoAccountRequired" => @review_demo_account_required,
          "demoAccountName" => @review_demo_account_name,
          "demoAccountPassword" => @review_demo_account_password,
          "notes" => @review_notes
        }
      }]
    when %r{\A/v1/builds/.+/betaBuildLocalizations\z}
      []
    when "/v1/apps/6805117080/appStoreVersions"
      platform = query.fetch("filter[platform]")
      versions = configured_or_default_app_store_versions(platform, query["filter[versionString]"])
      requested_version = query["filter[versionString]"]
      requested_version ? versions.select { |item| item.dig("attributes", "versionString") == requested_version } : versions
    when %r{\A/v1/appStoreVersions/(version-(?:IOS|MAC_OS)(?:-[^/]+)?)/appStoreVersionLocalizations\z}
      version_id = Regexp.last_match(1)
      @app_store_localizations || %w[de-DE en-US].map do |locale|
        {
          "type" => "appStoreVersionLocalizations",
          "id" => "#{version_id}-#{locale}",
          "attributes" => { "locale" => locale, "whatsNew" => "Old notes" }
        }
      end
    when "/v1/apps/6805117080/inAppPurchasesV2"
      in_app_purchases
    when "/v1/bundleIds"
      [{
        "type" => "bundleIds",
        "id" => "bundle-id-encrypted-memories",
        "attributes" => {
          "identifier" => @app_bundle_identifier,
          "platform" => "UNIVERSAL"
        }
      }]
    when "/v1/bundleIds/bundle-id-encrypted-memories/bundleIdCapabilities"
      @bundle_id_capabilities.map.with_index do |capability_type, index|
        {
          "type" => "bundleIdCapabilities",
          "id" => "capability-#{index}",
          "attributes" => { "capabilityType" => capability_type }
        }
      end
    when %r{\A/v2/inAppPurchases/(iap-\d+)/versions\z}
      in_app_purchase_versions(Regexp.last_match(1))
    when %r{\A/v1/inAppPurchaseVersions/(iap-\d+)-version-\d+/localizations\z}
      in_app_purchase_localizations(Regexp.last_match(1))
    when %r{\A/v1/inAppPurchasePriceSchedules/schedule-(iap-\d+)/manualPrices\z}
      in_app_purchase_prices(Regexp.last_match(1))
    when %r{\A/v1/inAppPurchaseAvailabilities/availability-(iap-\d+)/availableTerritories\z}
      @in_app_purchase_available_territories.map { |id| { "type" => "territories", "id" => id } }
    when "/v1/apps/6805117080/reviewSubmissions"
      platform = query.fetch("filter[platform]")
      states = query["filter[state]"]&.split(",")
      @review_submissions.select do |submission|
        submission.dig("attributes", "platform") == platform &&
          (states.nil? || states.include?(submission.dig("attributes", "state")))
      end
    when %r{\A/v1/reviewSubmissions/.+/items\z}
      @review_items
    else
      raise "Unexpected collection #{path}"
    end
  end

  def get(path, query: {})
    @calls << [:get, path, query]
    if path == "/v1/apps/6805117080"
      return {
        "data" => {
          "type" => "apps",
          "id" => "6805117080",
          "attributes" => { "bundleId" => @app_bundle_identifier }
        }
      }
    end
    if path.match?(%r{\A/v1/appStoreVersions/.+/appStoreReviewDetail\z})
      return {
        "data" => {
          "type" => "appStoreReviewDetails",
          "id" => "review-detail",
          "attributes" => {
            "contactFirstName" => "App",
            "contactLastName" => "Reviewer",
            "contactPhone" => @beta_phone,
            "contactEmail" => "review@example.com",
            "demoAccountRequired" => @review_demo_account_required,
            "demoAccountName" => @review_demo_account_name,
            "demoAccountPassword" => @review_demo_account_password,
            "notes" => @review_notes
          }
        }
      }
    end
    if (match = %r{\A/v2/inAppPurchases/(iap-\d+)/iapPriceSchedule\z}.match(path))
      return {
        "data" => {
          "type" => "inAppPurchasePriceSchedules",
          "id" => "schedule-#{match[1]}"
        }
      }
    end
    if (match = %r{\A/v2/inAppPurchases/(iap-\d+)/inAppPurchaseAvailability\z}.match(path))
      return {
        "data" => {
          "type" => "inAppPurchaseAvailabilities",
          "id" => "availability-#{match[1]}"
        }
      }
    end
    if path.match?(%r{\A/v2/inAppPurchases/.+\z})
      product = in_app_purchases.find { |item| path.end_with?(item.fetch("id")) }
      raise "Unexpected in-app purchase #{path}" unless product

      return in_app_purchase_details(product)
    end
    if path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
      platform = path.include?("MAC_OS") ? "MAC_OS" : "IOS"
      return { "data" => { "type" => "builds", "id" => "build-#{platform}" } }
    end
    if (match = %r{\A/v1/appStoreVersions/([^/]+)\z}.match(path))
      version = @known_app_store_versions.fetch(match[1])
      finish_pending_cancellation(version)
      return { "data" => version }
    end
    if (match = %r{\A/v1/reviewSubmissions/(.+)\z}.match(path))
      submission = @review_submissions.find { |item| item.fetch("id") == match[1] }
      raise "Unexpected review submission #{path}" unless submission

      return { "data" => submission }
    end

    {
      "data" => {
        "relationships" => {
          "betaAppReviewSubmission" => { "data" => nil }
        }
      },
      "included" => []
    }
  end

  def post(path, body:)
    @calls << [:post, path, body]
    if localization_write?(path) && (conflict = localization_lock_conflict!)
      raise AppStoreConnect::APIError.new(
        "Simulated App Store Connect whatsNew lock: Attribute 'whatsNew' cannot be edited at this time",
        status: 409,
        codes: @localization_lock_codes
      )
    end
    if path == "/v1/appStoreVersions"
      platform = body.dig(:data, :attributes, :platform)
      version = {
        "type" => "appStoreVersions",
        "id" => "version-#{platform}",
        "attributes" => {
          "platform" => platform,
          "versionString" => body.dig(:data, :attributes, :versionString),
          "appVersionState" => "PREPARE_FOR_SUBMISSION",
          "releaseType" => body.dig(:data, :attributes, :releaseType)
        }
      }
      @created_app_store_versions[platform] = version
      configured = @configured_app_store_versions&.fetch(platform, nil)
      configured << version if configured
      @known_app_store_versions[version.fetch("id")] = version
      return { "data" => version }
    end
    if path == "/v1/reviewSubmissions"
      platform = body.dig(:data, :attributes, :platform)
      submission = {
        "id" => "review-submission-#{platform}",
        "attributes" => { "platform" => platform, "state" => "READY_FOR_REVIEW" }
      }
      @review_submissions << submission
      return { "data" => submission }
    end

    { "data" => { "id" => "created" } }
  end

  def patch(path, body:)
    @calls << [:patch, path, body]
    if localization_write?(path) && (conflict = localization_lock_conflict!)
      raise AppStoreConnect::APIError.new(
        "Simulated App Store Connect whatsNew lock: Attribute 'whatsNew' cannot be edited at this time",
        status: 409,
        codes: @localization_lock_codes
      )
    end
    if body.dig(:data, :attributes, :canceled) == true &&
       (match = %r{\A/v1/reviewSubmissions/(.+)\z}.match(path))
      submission = @review_submissions.find { |item| item.fetch("id") == match[1] }
      raise "Unexpected review submission #{path}" unless submission

      version_id = submission.dig("relationships", "appStoreVersionForReview", "data", "id")
      if @cancel_transition_reads.positive?
        submission["attributes"]["state"] = "CANCELING"
        @pending_cancellations[version_id] = @cancel_transition_reads
      else
        submission["attributes"]["state"] = "COMPLETE"
        @known_app_store_versions.fetch(version_id)["attributes"]["appVersionState"] = "DEVELOPER_REJECTED"
      end
      if @cancel_error_status && !@cancel_error_consumed
        @cancel_error_consumed = true
        raise AppStoreConnect::APIError.new(
          "Simulated App Store Connect cancellation race",
          status: @cancel_error_status,
          codes: ["STATE_ERROR"]
        )
      end
    end
    if (match = %r{\A/v1/betaGroups/([^/]+)\z}.match(path)) && body.dig(:data, :attributes, :publicLinkEnabled)
      raise AppStoreConnect::TransportError, "Simulated connection reset" if @public_link_error_status == :transport
      if @public_link_error_status
        raise AppStoreConnect::APIError.new(
          "Simulated public link refusal",
          status: @public_link_error_status,
          codes: ["STATE_ERROR"]
        )
      end
      return {
        "data" => {
          "type" => "betaGroups",
          "id" => match[1],
          "attributes" => { "publicLinkEnabled" => true, "publicLink" => "https://testflight.apple.com/join/TESTLINK" }
        }
      }
    end
    if (match = %r{\A/v1/appStoreVersions/([^/]+)\z}.match(path))
      version = @known_app_store_versions.fetch(match[1])
      attributes = body.fetch(:data).fetch(:attributes, {})
      if attributes.key?(:versionString) && @rename_error_status && !@rename_error_consumed
        @rename_error_consumed = true
        if @rename_mutates_before_error
          attributes.each { |name, value| version.fetch("attributes")[name.to_s] = value }
        end
        raise AppStoreConnect::APIError.new(
          "Simulated App Store Connect version update race",
          status: @rename_error_status,
          codes: ["STATE_ERROR"]
        )
      end
      attributes.each do |name, value|
        version.fetch("attributes")[name.to_s] = value
      end
      return { "data" => version }
    end
    { "data" => { "id" => "updated" } }
  end

  private

  def localization_write?(path)
    path.start_with?("/v1/appStoreVersionLocalizations")
  end

  # Consumes one simulated 409 whatsNew lock. When configured, also transitions the
  # known versions to WAITING_FOR_REVIEW so a subsequent state re-read sees a
  # submitted state (mirrors Apple locking notes once a version is in review).
  # Apple pairs a version waiting for review with an active review submission, so a
  # completed attempt for a re-submitted version is reopened alongside the transition.
  def localization_lock_conflict!
    return false unless @localization_lock_conflicts.positive?

    @localization_lock_conflicts -= 1
    if @localization_conflict_transitions_to_submitted
      @known_app_store_versions.each_value do |version|
        version["attributes"]["appVersionState"] = "WAITING_FOR_REVIEW"
        @review_submissions.each do |submission|
          next unless submission.dig("relationships", "appStoreVersionForReview", "data", "id") == version.fetch("id")
          next unless submission.dig("attributes", "state") == "COMPLETE"

          submission["attributes"]["state"] = "WAITING_FOR_REVIEW"
        end
      end
    end
    true
  end

  def finish_pending_cancellation(version)
    remaining_reads = @pending_cancellations[version.fetch("id")]
    return unless remaining_reads

    if remaining_reads.positive?
      @pending_cancellations[version.fetch("id")] = remaining_reads - 1
      return
    end

    version["attributes"]["appVersionState"] = "DEVELOPER_REJECTED"
    submission = @review_submissions.find do |item|
      item.dig("relationships", "appStoreVersionForReview", "data", "id") == version.fetch("id")
    end
    submission["attributes"]["state"] = "COMPLETE" if submission
    @pending_cancellations.delete(version.fetch("id"))
  end

  def configured_or_default_app_store_versions(platform, requested_version)
    if @configured_app_store_versions
      versions = @configured_app_store_versions.fetch(platform, [])
      versions.each { |version| @known_app_store_versions[version.fetch("id")] = version }
      return versions
    end

    created = @created_app_store_versions[platform]
    return [created] if created
    return [] unless @app_store_versions_exist

    version_string = requested_version || "1.0.0"
    state = @version_state.respond_to?(:fetch) ? @version_state.fetch(platform) : @version_state
    version = {
      "type" => "appStoreVersions",
      "id" => "version-#{platform}",
      "attributes" => {
        "platform" => platform,
        "versionString" => version_string,
        "appVersionState" => state,
        "releaseType" => @release_type
      }
    }
    @known_app_store_versions[version.fetch("id")] = version
    [version]
  end

  def in_app_purchase_contract
    @in_app_purchase_contract ||= JSON.parse(
      File.read(AppStoreConnect::IN_APP_PURCHASE_CONTRACT_PATH, encoding: "UTF-8")
    )
  end

  def in_app_purchases
    in_app_purchase_contract.fetch("products").map.with_index do |expected, index|
      {
        "type" => "inAppPurchases",
        "id" => "iap-#{index}",
        "attributes" => {
          "name" => expected.fetch("referenceName"),
          "productId" => expected.fetch("productId"),
          "inAppPurchaseType" => expected.fetch("type"),
          "state" => @in_app_purchase_state,
          "reviewNote" => if @in_app_purchase_review_note == :contract
                            in_app_purchase_contract.fetch("reviewNote")
                          else
                            @in_app_purchase_review_note
                          end
        }
      }
    end
  end

  def in_app_purchase_versions(product_id)
    @in_app_purchase_versions.map do |version|
      {
        "type" => "inAppPurchaseVersions",
        "id" => "#{product_id}-version-#{version.fetch('version')}",
        "attributes" => version
      }
    end
  end

  def in_app_purchase_localizations(product_id)
    product = in_app_purchases.find { |item| item.fetch("id") == product_id }
    expected = in_app_purchase_contract.fetch("products").find do |item|
      item.fetch("productId") == product.dig("attributes", "productId")
    end
    expected.fetch("localizations").map do |locale, values|
      {
        "type" => "inAppPurchaseLocalizations",
        "id" => "#{product_id}-#{locale}",
        "attributes" => {
          "locale" => locale,
          "name" => values.fetch("name"),
          "description" => @in_app_purchase_description
        }
      }
    end
  end

  def in_app_purchase_prices(product_id)
    @in_app_purchase_prices.map.with_index do |attributes, index|
      {
        "type" => "inAppPurchasePrices",
        "id" => "#{product_id}-price-#{index}",
        "attributes" => attributes.merge("manual" => true)
      }
    end
  end

  def in_app_purchase_details(product)
    screenshot = if @in_app_purchase_screenshot_state
                   { "type" => "inAppPurchaseAppStoreReviewScreenshots", "id" => "screenshot-#{product.fetch('id')}" }
                 end
    screenshot_resource = if screenshot
                            {
                              "type" => screenshot.fetch("type"),
                              "id" => screenshot.fetch("id"),
                              "attributes" => {
                                "fileName" => "tip-review.png",
                                "assetDeliveryState" => { "state" => @in_app_purchase_screenshot_state }
                              }
                            }
                          end
    {
      "data" => {
        "relationships" => {
          "appStoreReviewScreenshot" => { "data" => screenshot }
        }
      },
      "included" => [screenshot_resource].compact
    }
  end

  def build(platform)
    {
      "type" => "builds",
      "id" => "build-#{platform}",
      "attributes" => {
        "processingState" => "VALID",
        "usesNonExemptEncryption" => false
      }
    }
  end

  def group(name, internal)
    {
      "type" => "betaGroups",
      "id" => "group-#{internal ? "internal" : "external"}",
      "attributes" => {
        "name" => name,
        "isInternalGroup" => internal,
        "iosBuildsAvailableForAppleSiliconMac" => true,
        "iosBuildsAvailableForAppleVision" => true
      }
    }
  end
end

class BuildHistoryAppStoreConnectClient
  attr_reader :calls

  def initialize(builds)
    @builds = builds
    @calls = []
  end

  def collection(path, query: {})
    raise "Unexpected collection #{path}" unless path == "/v1/builds"

    @calls << [:collection, path, query]
    @builds.select do |build|
      build.fetch("testPlatform") == query.fetch("filter[preReleaseVersion.platform]") &&
        (!query.key?("filter[preReleaseVersion.version]") ||
          build.fetch("testMarketingVersion") == query.fetch("filter[preReleaseVersion.version]")) &&
        (!query.key?("filter[version]") ||
          build.dig("attributes", "version") == query.fetch("filter[version]"))
    end
  end
end

class AppStoreConnectTest < Minitest::Test
  def setup
    @client = FakeAppStoreConnectClient.new
    @manager = AppStoreConnect::ReleaseManager.new(
      client: @client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )
  end

  def build_history_record(platform, marketing_version, build_number, state: "VALID")
    {
      "type" => "builds",
      "id" => "build-#{platform}-#{marketing_version}-#{build_number}",
      "testPlatform" => platform,
      "testMarketingVersion" => marketing_version,
      "attributes" => {
        "version" => build_number,
        "processingState" => state,
        "usesNonExemptEncryption" => false
      }
    }
  end

  def manager_for_build_history(builds)
    AppStoreConnect::ReleaseManager.new(
      client: BuildHistoryAppStoreConnectClient.new(builds),
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )
  end

  def test_jwt_uses_a_valid_es256_signature
    key = OpenSSL::PKey::EC.generate("prime256v1")
    token = AppStoreConnect.jwt(
      issuer_id: "issuer",
      key_id: "KEY123",
      private_key: key.to_pem,
      now: 1_700_000_000
    )
    header, claims, raw_signature = token.split(".").map { |part| Base64.urlsafe_decode64(part) }

    assert_equal({ "alg" => "ES256", "kid" => "KEY123", "typ" => "JWT" }, JSON.parse(header))
    assert_equal 1_700_001_200, JSON.parse(claims).fetch("exp")
    assert_equal 64, raw_signature.bytesize

    r = OpenSSL::BN.new(raw_signature.byteslice(0, 32), 2)
    s = OpenSSL::BN.new(raw_signature.byteslice(32, 32), 2)
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s)]).to_der
    assert key.verify(OpenSSL::Digest.new("SHA256"), der, token.split(".").first(2).join("."))
  end

  def test_build_lookup_requires_app_store_eligible_platform_build
    filters = AppStoreConnect.build_filters(
      app_id: "6805117080",
      version: "1.0.0",
      build_number: "714",
      platform: "IOS"
    )

    assert_equal "6805117080", filters.fetch("filter[app]")
    assert_equal "1.0.0", filters.fetch("filter[preReleaseVersion.version]")
    assert_equal "714", filters.fetch("filter[version]")
    assert_equal "IOS", filters.fetch("filter[preReleaseVersion.platform]")
    assert_equal "APP_STORE_ELIGIBLE", filters.fetch("filter[buildAudienceType]")
  end

  def test_build_history_lookup_can_scope_ios_to_one_marketing_version
    filters = AppStoreConnect.build_history_filters(
      app_id: "6805117080",
      platform: "IOS",
      version: "1.0.2"
    )

    assert_equal "6805117080", filters.fetch("filter[app]")
    assert_equal "IOS", filters.fetch("filter[preReleaseVersion.platform]")
    assert_equal "1.0.2", filters.fetch("filter[preReleaseVersion.version]")
    assert_equal "APP_STORE_ELIGIBLE", filters.fetch("filter[buildAudienceType]")
    assert_equal "version", filters.fetch("fields[builds]")
  end

  def test_build_number_validation_accepts_next_number_and_an_exact_retry
    builds = [
      build_history_record("IOS", "1.0.2", "382818668"),
      build_history_record("MAC_OS", "1.0.2", "382818668")
    ]
    manager = manager_for_build_history(builds)

    assert manager.validate_build_number(version: "1.0.2", build_number: "382818668")
    assert manager.validate_build_number(version: "1.0.2", build_number: "382818669")
  end

  def test_build_number_validation_rejects_a_non_monotonic_new_build()
    builds = [
      build_history_record("IOS", "1.0.2", "382818668"),
      build_history_record("MAC_OS", "1.0.2", "382818668")
    ]
    manager = manager_for_build_history(builds)

    error = assert_raises(AppStoreConnect::Error) do
      manager.validate_build_number(version: "1.0.3", build_number: "382818668")
    end

    assert_match(/MAC_OS build 382818668 must be greater than existing build 382818668/, error.message)
  end

  def test_cli_parses_platform_scoped_localizations
    options = AppStoreConnect::CLI.parse_options([
      "--localization", "IOS:en-US=/tmp/ios.txt",
      "--localization", "MAC_OS:en-US=/tmp/macos.txt"
    ])

    assert_equal(
      {
        "IOS" => { "en-US" => "/tmp/ios.txt" },
        "MAC_OS" => { "en-US" => "/tmp/macos.txt" }
      },
      options.fetch(:localizations)
    )
  end

  def test_cli_rejects_an_unscoped_localization
    error = assert_raises(OptionParser::InvalidArgument) do
      AppStoreConnect::CLI.parse_options(["--localization", "en-US=/tmp/notes.txt"])
    end

    assert_match(/PLATFORM:LOCALE=PATH/, error.message)
  end

  def test_beta_group_create_uses_only_attributes_allowed_by_the_create_contract
    payload = AppStoreConnect.beta_group_payload(
      app_id: "6805117080",
      name: "Internal Testers",
      internal: true
    )
    attributes = payload.dig(:data, :attributes)

    assert_equal true, attributes.fetch(:isInternalGroup)
    refute attributes.key?(:iosBuildsAvailableForAppleSiliconMac)
    refute attributes.key?(:iosBuildsAvailableForAppleVision)
  end

  def test_client_retries_rate_limits_but_not_ambiguous_post_server_errors
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(_seconds) {}
    )
    unavailable = Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")
    rate_limited = Net::HTTPTooManyRequests.new("1.1", "429", "Rate limited")

    assert_equal false, client.send(:retryable?, :post, unavailable)
    assert_equal true, client.send(:retryable?, :get, unavailable)
    assert_equal true, client.send(:retryable?, :post, rate_limited)
    assert_equal true, client.send(:retryable?, :patch, rate_limited)
  end

  def test_client_retry_matrix_covers_idempotent_and_post_statuses
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem
    )

    assert client.send(:retryable?, :get, Net::HTTPInternalServerError.new("1.1", "500", "Error"))
    assert client.send(:retryable?, :patch, Net::HTTPBadGateway.new("1.1", "502", "Error"))
    refute client.send(:retryable?, :post, Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable"))
    refute client.send(:retryable?, :post, Net::HTTPInternalServerError.new("1.1", "500", "Error"))
    refute client.send(:retryable?, :post, Net::HTTPBadRequest.new("1.1", "400", "Bad request"))
  end

  def test_client_retries_get_with_retry_after_without_logging_query_or_token
    responses = [
      Net::HTTPTooManyRequests.new("1.1", "429", "Rate limited"),
      Net::HTTPOK.new("1.1", "200", "OK")
    ]
    responses.first["Retry-After"] = "3"
    success_body = JSON.generate("ok" => true)
    responses.last.define_singleton_method(:body) { success_body }
    requests = []
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      requests << request
      responses.shift
    end
    sleeps = []
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(seconds) { sleeps << seconds }
    )

    output, = capture_io do
      assert_equal({ "ok" => true }, Net::HTTP.stub(:start, ->(*args, &block) { block.call(fake_http) }) {
        client.get("/v1/apps?secret=query-token")
      })
    end

    assert_equal [3], sleeps
    assert_equal 2, requests.length
    assert_includes output, "GET /v1/apps (HTTP 429) attempt 1/6 wait 3s"
    refute_includes output, "query-token"
    refute_includes output, "Authorization"
  end

  def test_client_retries_post_only_on_open_timeout
    responses = [Net::HTTPOK.new("1.1", "200", "OK")]
    success_body = JSON.generate("created" => true)
    responses.first.define_singleton_method(:body) { success_body }
    calls = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |_request|
      calls += 1
      raise Net::OpenTimeout if calls == 1

      responses.fetch(0)
    end
    sleeps = []
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(seconds) { sleeps << seconds }
    )

    result = Net::HTTP.stub(:start, ->(*args, &block) { block.call(fake_http) }) do
      client.post("/v1/apps", body: { name: "test" })
    end

    assert_equal({ "created" => true }, result)
    assert_equal 2, calls
    assert_equal [2], sleeps
  end

  def test_client_does_not_retry_post_after_read_timeout
    calls = 0
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |_request|
      calls += 1
      raise Net::ReadTimeout
    end
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(_seconds) { flunk "read timeout must not be retried" }
    )

    error = assert_raises(AppStoreConnect::TransportError) do
      Net::HTTP.stub(:start, ->(*args, &block) { block.call(fake_http) }) do
        client.post("/v1/apps", body: { name: "test" })
      end
    end

    assert_equal 1, calls
    assert_match(/Net::ReadTimeout/, error.message)
  end

  def test_client_retries_unauthorized_once_with_a_new_attempt
    responses = [
      Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized"),
      Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    ]
    responses.each do |response|
      response.define_singleton_method(:body) { JSON.generate("errors" => []) }
    end
    requests = []
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      requests << request
      responses.shift
    end
    sleeps = []
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(seconds) { sleeps << seconds }
    )

    error = assert_raises(AppStoreConnect::APIError) do
      Net::HTTP.stub(:start, ->(*args, &block) { block.call(fake_http) }) { client.get("/v1/apps") }
    end

    assert_equal 401, error.status
    assert_equal 2, requests.length
    assert_equal [2], sleeps
  end

  def test_failure_report_classifies_api_and_transport_errors
    transport = AppStoreConnect::failure_report(AppStoreConnect::TransportError.new("network down"))
    assert_equal :apple_or_network_outage, transport.fetch(:category)
    assert_equal true, transport.fetch(:rerun_safe)

    credentials = AppStoreConnect::failure_report(
      AppStoreConnect::APIError.new("unauthorized", status: 401)
    )
    assert_equal :credentials, credentials.fetch(:category)
    assert_match(/APP_STORE_CONNECT_ISSUER_ID/, credentials.fetch(:remediation))

    conflict = AppStoreConnect::failure_report(
      AppStoreConnect::APIError.new("version conflict", status: 409)
    )
    assert_equal :apple_state_conflict, conflict.fetch(:category)
    assert_match(/named version/, conflict.fetch(:remediation))
  end

  def test_failure_report_uses_explicit_error_attributes
    error = AppStoreConnect::Error.new(
      "owner action",
      category: :configuration,
      remediation: "Set the repository secret."
    )

    report = AppStoreConnect::failure_report(error)

    assert_equal :configuration, report.fetch(:category)
    assert_equal "Set the repository secret.", report.fetch(:remediation)
    assert_equal false, report.fetch(:rerun_safe)
  end

  def test_wait_for_builds_timeout_includes_reusable_build_remediation
    client = Class.new do
      def collection(_path, query: {})
        []
      end
    end.new
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      monotonic_clock: -> { 1 }
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.wait_for_builds(version: "1.0.0", build_number: "714", timeout_seconds: 0)
    end

    assert_match(/IOS=MISSING, MAC_OS=MISSING/, error.message)
    assert_match(/uploaded build is reused/, error.remediation)
  end

  def test_validate_export_compliance_includes_owner_remediation
    error = assert_raises(AppStoreConnect::Error) do
      @manager.send(:validate_export_compliance, { "id" => "build-1", "attributes" => {} })
    end

    assert_match(/ITSAppUsesNonExemptEncryption/, error.remediation)
    assert_match(/export compliance question/, error.remediation)
  end

  def test_client_preserves_structured_api_error_status_and_codes
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem
    )
    response = Struct.new(:code, :body).new(
      "409",
      JSON.generate(errors: [{ code: "STATE_ERROR", title: "Conflict", detail: "The state changed." }])
    )

    error = client.send(:api_error, response)

    assert_instance_of AppStoreConnect::APIError, error
    assert_equal 409, error.status
    assert_equal ["STATE_ERROR"], error.codes
    assert_match(/The state changed/, error.message)
  end

  def test_in_app_purchase_preflight_accepts_complete_first_release_products
    assert @manager.validate_in_app_purchases

    version_requests = @client.calls.count do |method, path, _query|
      method == :collection && path.match?(%r{\A/v2/inAppPurchases/[^/]+/versions\z})
    end
    localization_requests = @client.calls.count do |method, path, _query|
      method == :collection && path.match?(%r{\A/v1/inAppPurchaseVersions/[^/]+/localizations\z})
    end
    expected_count = JSON.parse(
      File.read(AppStoreConnect::IN_APP_PURCHASE_CONTRACT_PATH, encoding: "UTF-8")
    ).fetch("products").length
    assert_equal expected_count, version_requests
    assert_equal expected_count, localization_requests

    localization_queries = @client.calls.filter_map do |method, path, query|
      query if method == :collection && path.match?(%r{\A/v1/inAppPurchaseVersions/[^/]+/localizations\z})
    end
    assert localization_queries.all? { |query|
      query.fetch("fields[inAppPurchaseLocalizations]") == "name,locale"
    }

    capability_request = @client.calls.find do |method, path, _query|
      method == :collection && path.end_with?("/bundleIdCapabilities")
    end
    refute_nil capability_request
    assert_equal "capabilityType", capability_request.last.fetch("fields[bundleIdCapabilities]")
    refute capability_request.last.key?("limit")
  end

  def test_sandbox_preflight_does_not_require_review_submission_metadata
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_state: "MISSING_METADATA",
      in_app_purchase_review_note: "not ready for review",
      in_app_purchase_screenshot_state: nil
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    assert manager.validate_in_app_purchase_sandbox
    refute client.calls.any? { |method, path, _query|
      method == :get && path.match?(%r{\A/v2/inAppPurchases/[^/]+\z})
    }
  end

  def test_review_preflight_rejects_a_missing_metadata_product_state
    client = FakeAppStoreConnectClient.new(in_app_purchase_state: "MISSING_METADATA")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchases }

    assert_match(/product state "MISSING_METADATA"/, error.message)
  end

  def test_sandbox_preflight_rejects_a_product_that_needs_developer_action
    client = FakeAppStoreConnectClient.new(in_app_purchase_state: "DEVELOPER_ACTION_NEEDED")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchase_sandbox }

    assert_match(/product state "DEVELOPER_ACTION_NEEDED"/, error.message)
  end

  def test_sandbox_preflight_rejects_missing_store_configuration
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_prices: [{ "startDate" => (Date.today + 1).iso8601, "endDate" => nil }],
      in_app_purchase_available_territories: ["AUT"]
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchase_sandbox }

    assert_match(/has no price active/, error.message)
    assert_match(/unavailable in required territories: USA/, error.message)
  end

  def test_sandbox_preflight_rejects_an_app_bundle_identifier_mismatch
    client = FakeAppStoreConnectClient.new(app_bundle_identifier: "at.oncloud.wrong")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchase_sandbox }

    assert_match(/app has bundle identifier "at.oncloud.wrong"/, error.message)
  end

  def test_sandbox_preflight_rejects_a_bundle_id_without_in_app_purchase
    client = FakeAppStoreConnectClient.new(bundle_id_capabilities: [])
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchase_sandbox }

    assert_match(/does not enable In-App Purchase/, error.message)
    refute client.calls.any? { |method, path, _query|
      method == :collection && path == "/v1/apps/6805117080/inAppPurchasesV2"
    }
  end

  def test_in_app_purchase_preflight_rejects_missing_review_metadata
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_versions: [{ "version" => 1, "state" => "REJECTED" }],
      in_app_purchase_review_note: "",
      in_app_purchase_screenshot_state: nil
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchases }

    assert_match(/latest metadata version has state "REJECTED"/, error.message)
    assert_match(/unexpected review note/, error.message)
    assert_match(/no App Review screenshot/, error.message)
  end

  def test_in_app_purchase_preflight_rejects_unprocessed_review_assets
    client = FakeAppStoreConnectClient.new(in_app_purchase_screenshot_state: "UPLOAD_COMPLETE")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchases }

    assert_match(/review screenshot has delivery state "UPLOAD_COMPLETE"/, error.message)
  end

  def test_in_app_purchase_preflight_uses_the_latest_active_metadata_version
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_versions: [
        { "version" => 1, "state" => "APPROVED" },
        { "version" => 2, "state" => "PREPARE_FOR_SUBMISSION" },
      ]
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    assert manager.validate_in_app_purchase_sandbox
    localization_paths = client.calls.filter_map do |method, path, _query|
      path if method == :collection && path.include?("/localizations")
    end
    expected_count = JSON.parse(
      File.read(AppStoreConnect::IN_APP_PURCHASE_CONTRACT_PATH, encoding: "UTF-8")
    ).fetch("products").length
    assert_equal expected_count, localization_paths.length
    assert localization_paths.all? { |path| path.include?("-version-2/") }
  end

  def test_in_app_purchase_preflight_does_not_fall_back_from_a_rejected_latest_version
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_versions: [
        { "version" => 1, "state" => "APPROVED" },
        { "version" => 2, "state" => "REJECTED" },
      ]
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { manager.validate_in_app_purchase_sandbox }

    assert_match(/latest metadata version has state "REJECTED"/, error.message)
  end

  def test_internal_distribution_adds_both_platform_builds
    @manager.distribute_internal(
      version: "1.0.0",
      build_number: "714",
      group_name: "Internal Testers"
    )

    call = @client.calls.find do |method, path, _body|
      method == :post && path == "/v1/betaGroups/group-internal/relationships/builds"
    end
    refute_nil call
    ids = call.last.fetch(:data).map { |item| item.fetch(:id) }
    assert_equal %w[build-IOS build-MAC_OS], ids

    compatibility_call = @client.calls.find do |method, path, _body|
      method == :patch && path == "/v1/betaGroups/group-internal"
    end
    assert_equal false, compatibility_call.last.dig(:data, :attributes, :iosBuildsAvailableForAppleSiliconMac)
  end

  def test_internal_distribution_sets_platform_specific_release_notes
    ios = Tempfile.new("internal-ios-what-to-test")
    macos = Tempfile.new("internal-macos-what-to-test")
    ios.write("Test the mobile viewer.")
    macos.write("Test the desktop viewer.")
    ios.close
    macos.close

    @manager.distribute_internal(
      version: "1.0.0",
      build_number: "714",
      group_name: "Internal Testers",
      localization_paths: {
        "IOS" => { "en-US" => ios.path },
        "MAC_OS" => { "en-US" => macos.path }
      }
    )

    localization_posts = @client.calls.select do |method, path, _body|
      method == :post && path == "/v1/betaBuildLocalizations"
    end
    notes_by_build = localization_posts.to_h do |_method, _path, body|
      [
        body.dig(:data, :relationships, :build, :data, :id),
        body.dig(:data, :attributes, :whatsNew)
      ]
    end
    assert_equal "Test the mobile viewer.", notes_by_build.fetch("build-IOS")
    assert_equal "Test the desktop viewer.", notes_by_build.fetch("build-MAC_OS")
  ensure
    ios&.unlink
    macos&.unlink
  end

  def test_external_distribution_sets_test_text_and_submits_both_builds
    file = Tempfile.new("what-to-test")
    file.write("Test sign-in and backup.")
    file.close

    @manager.distribute_external(
      version: "1.0.0",
      build_number: "714",
      group_name: "External Testers",
      localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => file.path }] }
    )

    localization_posts = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaBuildLocalizations"
    end
    review_posts = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaAppReviewSubmissions"
    end
    assert_equal 2, localization_posts
    assert_equal 2, review_posts
  ensure
    file&.unlink
  end

  def test_external_distribution_also_adds_both_builds_to_the_internal_group
    distribute_external(@manager)

    internal = @client.calls.find do |method, path, _body|
      method == :post && path == "/v1/betaGroups/group-internal/relationships/builds"
    end
    refute_nil internal
    assert_equal %w[build-IOS build-MAC_OS], internal.last.fetch(:data).map { |item| item.fetch(:id) }
  end

  def test_external_distribution_enables_the_public_link_and_reports_it
    Dir.mktmpdir do |directory|
      output = File.join(directory, "output")
      summary = File.join(directory, "summary")
      manager = AppStoreConnect::ReleaseManager.new(
        client: @client, app_id: "6805117080", output_path: output, summary_path: summary
      )

      distribute_external(manager)

      link_change = @client.calls.find do |method, path, body|
        method == :patch && path == "/v1/betaGroups/group-external" &&
          body.dig(:data, :attributes, :publicLinkEnabled) == true
      end
      refute_nil link_change
      assert_includes File.read(output), "public_link=https://testflight.apple.com/join/TESTLINK"
      assert_includes File.read(summary), "Public TestFlight link: https://testflight.apple.com/join/TESTLINK"
    end
  end

  def test_external_distribution_keeps_an_enabled_public_link
    external = {
      "type" => "betaGroups",
      "id" => "group-external",
      "attributes" => {
        "name" => "External Testers", "isInternalGroup" => false,
        "iosBuildsAvailableForAppleSiliconMac" => false, "iosBuildsAvailableForAppleVision" => false,
        "publicLinkEnabled" => true, "publicLink" => "https://testflight.apple.com/join/EXISTING"
      }
    }
    client = FakeAppStoreConnectClient.new(groups: [@client.send(:group, "Internal Testers", true), external])
    manager = AppStoreConnect::ReleaseManager.new(
      client: client, app_id: "6805117080", output_path: nil, summary_path: nil
    )

    distribute_external(manager)

    assert_empty(client.calls.select { |method, path, _body| method == :patch && path == "/v1/betaGroups/group-external" })
  end

  def test_external_distribution_succeeds_when_apple_refuses_the_public_link
    client = FakeAppStoreConnectClient.new(public_link_error_status: 409)
    manager = AppStoreConnect::ReleaseManager.new(
      client: client, app_id: "6805117080", output_path: nil, summary_path: nil
    )

    distribute_external(manager)

    review_posts = client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaAppReviewSubmissions"
    end
    assert_equal 2, review_posts
  end

  def test_external_distribution_succeeds_when_the_public_link_request_fails_in_transport
    Dir.mktmpdir do |directory|
      summary = File.join(directory, "summary")
      client = FakeAppStoreConnectClient.new(public_link_error_status: :transport)
      manager = AppStoreConnect::ReleaseManager.new(
        client: client, app_id: "6805117080", output_path: nil, summary_path: summary
      )

      distribute_external(manager)

      assert_includes File.read(summary), "The beta was submitted, but the public TestFlight link could not be enabled"
    end
  end

  def test_external_distribution_refuses_several_internal_groups
    client = FakeAppStoreConnectClient.new(groups: [
      @client.send(:group, "Internal Testers", true),
      @client.send(:group, "Team", true).merge("id" => "group-team"),
      @client.send(:group, "External Testers", false)
    ])
    manager = AppStoreConnect::ReleaseManager.new(
      client: client, app_id: "6805117080", output_path: nil, summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) { distribute_external(manager) }

    assert_match(/exactly one internal TestFlight group/, error.message)
  end

  def test_external_distribution_keeps_mobile_builds_off_the_mac_in_the_internal_group
    distribute_external(@manager)

    internal_patch = @client.calls.find do |method, path, _body|
      method == :patch && path == "/v1/betaGroups/group-internal"
    end
    refute_nil internal_patch
    assert_equal false, internal_patch.last.dig(:data, :attributes, :iosBuildsAvailableForAppleSiliconMac)
  end

  def distribute_external(manager)
    manager.distribute_external(
      version: "1.0.0",
      build_number: "714",
      group_name: "External Testers",
      localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => __FILE__ }] }
    )
  end

  def test_external_distribution_does_not_require_app_store_review_metadata
    client = FakeAppStoreConnectClient.new(
      in_app_purchase_review_note: "not ready for review",
      in_app_purchase_screenshot_state: nil
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.distribute_external(
      version: "1.0.0",
      build_number: "714",
      group_name: "External Testers",
      localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => __FILE__ }] }
    )

    review_posts = client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaAppReviewSubmissions"
    end
    assert_equal 2, review_posts
  end

  def test_external_distribution_requires_an_internal_group
    client = FakeAppStoreConnectClient.new(groups: [{
      "id" => "external",
      "attributes" => { "name" => "External Testers", "isInternalGroup" => false }
    }])
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.distribute_external(
        version: "1.0.0",
        build_number: "714",
        group_name: "External Testers",
        localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => __FILE__ }] }
      )
    end
    assert_match(/internal TestFlight group/, error.message)
  end

  def test_external_distribution_requires_an_e164_review_phone
    client = FakeAppStoreConnectClient.new(beta_phone: "0043 123 456")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.distribute_external(
        version: "1.0.0",
        build_number: "714",
        group_name: "External Testers",
        localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => __FILE__ }] }
      )
    end
    assert_match(/E.164/, error.message)
  end

  def test_external_distribution_requires_a_demo_account
    client = FakeAppStoreConnectClient.new(review_demo_account_required: false)
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.distribute_external(
        version: "1.0.0",
        build_number: "714",
        group_name: "External Testers",
        localization_paths: AppStoreConnect::PLATFORMS.to_h { |platform| [platform, { "en-US" => __FILE__ }] }
      )
    end
    assert_match(/must require a demo account/, error.message)
  end

  def test_app_store_submission_uses_one_review_submission_per_platform
    @manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    attachment_calls = @client.calls.count do |method, path, _body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    item_calls = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissionItems"
    end
    submission_posts = @client.calls.select do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissions"
    end
    submit_calls = @client.calls.select do |method, path, _body|
      method == :patch && path.start_with?("/v1/reviewSubmissions/review-submission-")
    end

    assert_equal 2, attachment_calls
    assert_equal %w[IOS MAC_OS], submission_posts.map { |_method, _path, body| body.dig(:data, :attributes, :platform) }
    assert_equal 2, item_calls
    assert_equal 2, submit_calls.length
    assert submit_calls.all? { |_method, _path, body| body.dig(:data, :attributes, :submitted) == true }
  end

  def test_stable_release_creates_versions_sets_notes_and_automatic_release
    client = FakeAppStoreConnectClient.new(app_store_versions_exist: false)
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )
    german = Tempfile.new("de-DE")
    english = Tempfile.new("en-US")
    german.write("Verbesserte Videowiedergabe.")
    english.write("Improved video playback.")
    german.close
    english.close

    manager.prepare_app_store(
      version: "1.1.0",
      build_number: "714",
      submit: true,
      localization_paths: AppStoreConnect::PLATFORMS.to_h do |platform|
        [platform, { "de-DE" => german.path, "en-US" => english.path }]
      end,
      create_versions: true,
      automatic_release: true
    )

    version_posts = client.calls.select do |method, path, _body|
      method == :post && path == "/v1/appStoreVersions"
    end
    assert_equal %w[IOS MAC_OS], version_posts.map { |_method, _path, body| body.dig(:data, :attributes, :platform) }
    assert version_posts.all? do |_method, _path, body|
      body.dig(:data, :attributes, :releaseType) == "AFTER_APPROVAL"
    end

    attachment_calls = client.calls.select do |method, path, _body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    assert_equal(
      [
        ["/v1/appStoreVersions/version-IOS/relationships/build", "build-IOS"],
        ["/v1/appStoreVersions/version-MAC_OS/relationships/build", "build-MAC_OS"]
      ],
      attachment_calls.map { |_method, path, body| [path, body.dig(:data, :id)] }
    )

    first_review_item_index = client.calls.index do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissionItems"
    end
    refute_nil first_review_item_index
    assert attachment_calls.all? { |call| client.calls.index(call) < first_review_item_index }

    localization_patches = client.calls.select do |method, path, _body|
      method == :patch && path.start_with?("/v1/appStoreVersionLocalizations/")
    end
    assert_equal 4, localization_patches.length
    refute(client.calls.any? do |method, path, _body|
      method == :post && path == "/v1/appStoreVersionReleaseRequests"
    end)
  ensure
    german&.unlink
    english&.unlink
  end

  def test_stable_release_updates_manual_release_before_submission
    manager = AppStoreConnect::ReleaseManager.new(
      client: @client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.prepare_app_store(
      version: "1.0.0",
      build_number: "714",
      automatic_release: true
    )

    release_type_patches = @client.calls.select do |method, path, body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/version-(IOS|MAC_OS)\z}) &&
        body.dig(:data, :attributes, :releaseType) == "AFTER_APPROVAL"
    end
    assert_equal 2, release_type_patches.length
  end

  def test_stable_release_does_not_change_release_type_after_submission
    client = FakeAppStoreConnectClient.new(version_state: "WAITING_FOR_REVIEW")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.0",
        build_number: "714",
        automatic_release: true
      )
    end

    assert_match(/already submitted with release type MANUAL/, error.message)
  end

  def test_app_store_submission_requires_demo_credentials_for_each_platform
    client = FakeAppStoreConnectClient.new(review_demo_account_password: "")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: false)
    end

    assert_match(/IOS App Store review demo account fields are missing/, error.message)
  end

  def test_app_store_submission_requires_review_notes
    client = FakeAppStoreConnectClient.new(review_notes: "")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: false)
    end

    assert_match(/IOS App Store review notes are missing/, error.message)
  end

  def test_first_in_app_purchase_submission_cannot_bypass_app_store_connect
    client = FakeAppStoreConnectClient.new(in_app_purchase_state: "READY_TO_SUBMIT")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)
    end

    assert_match(/automatic submission requires APPROVED products/, error.message)
    review_submission_created = client.calls.any? do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissions"
    end
    refute review_submission_created
  end

  def test_app_store_rerun_validates_builds_without_duplicate_review_submissions
    client = FakeAppStoreConnectClient.new(version_state: "WAITING_FOR_REVIEW")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    review_posts = client.calls.count do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissions"
    end
    attachment_patches = client.calls.count do |method, path, _body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    assert_equal 0, review_posts
    assert_equal 0, attachment_patches
  end

  def test_app_store_rerun_finishes_only_the_platform_that_is_not_submitted
    client = FakeAppStoreConnectClient.new(
      version_state: { "IOS" => "WAITING_FOR_REVIEW", "MAC_OS" => "PREPARE_FOR_SUBMISSION" }
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    submission_platforms = client.calls.filter_map do |method, path, body|
      body.dig(:data, :attributes, :platform) if method == :post && path == "/v1/reviewSubmissions"
    end
    attachment_paths = client.calls.filter_map do |method, path, _body|
      path if method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    assert_equal ["MAC_OS"], submission_platforms
    assert_equal ["/v1/appStoreVersions/version-MAC_OS/relationships/build"], attachment_paths
  end

  def test_whats_new_409_skip_when_state_becomes_submitted_mid_flight
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.0", state: "PREPARE_FOR_SUBMISSION")]]
    end
    # The first localization write raises a 409 whatsNew lock; Apple moved the version
    # to WAITING_FOR_REVIEW between our state read and the write. The manager must
    # re-read the state, see the submitted state, and skip the write with a summary.
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      localization_lock_conflicts: 4,
      localization_conflict_transitions_to_submitted: true
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.0",
      build_number: "714",
      submit: false,
      localization_paths: {
        "IOS" => { "en-US" => __FILE__ },
        "MAC_OS" => { "en-US" => __FILE__ }
      }
    )
    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    assert_match(/Skipped whatsNew update for en-US \(App Store version moved to WAITING_FOR_REVIEW on Apple's side\)/, summary_content)
  ensure
    summary_file&.unlink
  end

  def test_new_stable_release_validates_then_cancels_and_renames_older_versions
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    cancellation_calls = client.calls.select do |method, path, body|
      method == :patch && path.start_with?("/v1/reviewSubmissions/old-review-") &&
        body.dig(:data, :attributes, :canceled) == true
    end
    assert_equal 2, cancellation_calls.length
    assert_equal(
      %w[old-review-IOS old-review-MAC_OS],
      cancellation_calls.map { |_method, path, _body| path.split("/").last }
    )

    rename_calls = client.calls.select do |method, path, body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/version-(?:IOS|MAC_OS)-1\.0\.1\z}) &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    end
    assert_equal 2, rename_calls.length
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
    assert_operator(
      cancellation_calls.map { |call| client.calls.index(call) }.max,
      :<,
      rename_calls.map { |call| client.calls.index(call) }.min
    )
  end

  def test_new_stable_release_cancels_only_the_platform_with_an_older_version
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "IN_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.2", state: "WAITING_FOR_REVIEW")]
    }
    submissions = [
      review_submission(platform: "IOS", version_id: "version-IOS-1.0.1", state: "IN_REVIEW"),
      review_submission(
        platform: "MAC_OS",
        version_id: "version-MAC_OS-1.0.2",
        state: "WAITING_FOR_REVIEW"
      )
    ]
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    cancellation_paths = client.calls.filter_map do |method, path, body|
      path if method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    assert_equal ["/v1/reviewSubmissions/old-review-IOS"], cancellation_paths
  end

  def test_stable_release_ignores_completed_review_history_for_the_same_version
    [false, true].each do |history_first|
      versions = {
        "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "IN_REVIEW")],
        "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.3", state: "WAITING_FOR_REVIEW")]
      }
      current = review_submission(platform: "IOS", version_id: "version-IOS-1.0.1", state: "IN_REVIEW")
      history = review_submission(platform: "IOS", version_id: "version-IOS-1.0.1", state: "COMPLETE")
      history["id"] = "historical-review-IOS"
      submissions = history_first ? [history, current] : [current, history]
      client = FakeAppStoreConnectClient.new(app_store_versions: versions, review_submissions: submissions)
      manager = AppStoreConnect::ReleaseManager.new(
        client: client, app_id: "6805117080", output_path: nil, summary_path: nil, sleeper: ->(_seconds) {}
      )

      manager.prepare_app_store(
        version: "1.0.3", build_number: "714", submit: true, create_versions: true, automatic_release: true
      )

      cancellations = client.calls.filter_map do |method, path, body|
        path if method == :patch && body.dig(:data, :attributes, :canceled) == true
      end
      assert_equal ["/v1/reviewSubmissions/old-review-IOS"], cancellations
      assert client.calls.any? { |method, path, body|
        method == :patch && path == "/v1/appStoreVersions/version-IOS-1.0.1" &&
          body.dig(:data, :attributes, :versionString) == "1.0.3"
      }
      refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
    end
  end

  def test_stable_release_refuses_ambiguous_review_history_before_mutating_either_platform
    # Two open attempts, undated completed attempts, or completed attempts with the same date stay ambiguous.
    [["IN_REVIEW", nil], ["COMPLETE", nil], ["COMPLETE", "2026-09-18T09:14:40Z"]].each do |state, date|
      versions = {
        "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "IN_REVIEW")],
        "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.3", state: "WAITING_FOR_REVIEW")]
      }
      submissions = (0..1).map do |index|
        item = review_submission(platform: "IOS", version_id: "version-IOS-1.0.1", state: state)
        item["id"] = "review-IOS-#{index}"
        item["attributes"]["submittedDate"] = date if date
        item
      end
      client = FakeAppStoreConnectClient.new(app_store_versions: versions, review_submissions: submissions)
      manager = AppStoreConnect::ReleaseManager.new(
        client: client, app_id: "6805117080", output_path: nil, summary_path: nil
      )

      error = assert_raises(AppStoreConnect::Error) do
        manager.prepare_app_store(
          version: "1.0.3", build_number: "714", submit: true, create_versions: true, automatic_release: true
        )
      end
      assert_includes error.message, "multiple IOS review submissions"
      refute client.calls.any? { |method, _path, _body| %i[patch post delete].include?(method) }
    end
  end

  def test_missing_platform_version_is_created_and_validated_before_any_cancellation
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
      "MAC_OS" => []
    }
    submissions = [
      review_submission(
        platform: "IOS",
        version_id: "version-IOS-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    ]
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = release_manager(client)

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    creation_index = client.calls.index do |method, path, body|
      method == :post && path == "/v1/appStoreVersions" &&
        body.dig(:data, :attributes, :platform) == "MAC_OS"
    end
    cancellation_index = client.calls.index do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    macos_review_preflight_index = client.calls.index do |method, path, _query|
      method == :get && path == "/v1/appStoreVersions/version-MAC_OS/appStoreReviewDetail"
    end
    refute_nil creation_index
    refute_nil macos_review_preflight_index
    refute_nil cancellation_index
    assert_operator creation_index, :<, macos_review_preflight_index
    assert_operator macos_review_preflight_index, :<, cancellation_index
  end

  def test_cancellation_conflict_reconciles_the_authoritative_apple_state
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.2", state: "WAITING_FOR_REVIEW")]
    }
    submissions = [
      review_submission(
        platform: "IOS",
        version_id: "version-IOS-1.0.1",
        state: "WAITING_FOR_REVIEW"
      ),
      review_submission(
        platform: "MAC_OS",
        version_id: "version-MAC_OS-1.0.2",
        state: "WAITING_FOR_REVIEW"
      )
    ]
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      cancel_error_status: 409
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    assert client.calls.any? { |method, path, body|
      method == :patch && path == "/v1/appStoreVersions/version-IOS-1.0.1" &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    }
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
  end

  def test_gap2_editable_predecessor_becomes_recoverable_and_renamed_instead_of_posted
    # Gap 2 regression test: PREPARE_FOR_SUBMISSION / READY_FOR_REVIEW predecessors
    # must be recoverable and renamed instead of creating a new version via POST.
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "PREPARE_FOR_SUBMISSION")]]
    end
    submissions = [] # No review submission yet — version is still editable
    client = FakeAppStoreConnectClient.new(app_store_versions: versions, review_submissions: submissions)
    manager = release_manager(client)

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    # Expect rename (PATCH), not create (POST)
    rename_call = client.calls.find do |method, path, body|
      method == :patch && path == "/v1/appStoreVersions/version-IOS-1.0.1" &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    end
    refute_nil rename_call, "Expected rename PATCH for IOS 1.0.1 → 1.0.2"

    create_calls = client.calls.select { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
    assert_empty create_calls, "Gap 2 fix prevented unnecessary POST when editable predecessor exists"

    # MAC_OS should behave identically
    mac_rename = client.calls.find do |method, path, body|
      method == :patch && path == "/v1/appStoreVersions/version-MAC_OS-1.0.1" &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    end
    refute_nil mac_rename, "Expected rename PATCH for MAC_OS 1.0.1 → 1.0.2"
  end

  def test_apple_rejected_predecessor_is_renamed_instead_of_blocking_the_release
    # Apple keeps REJECTED, METADATA_REJECTED, and INVALID_BINARY versions editable. The owner
    # resubmits them with a new build, so the workflow reuses the record like DEVELOPER_REJECTED.
    AppStoreConnect::APPLE_REJECTED_VERSION_STATES.each do |state|
      versions = AppStoreConnect::PLATFORMS.to_h do |platform|
        [platform, [app_store_version(platform: platform, version: "1.0.1", state: state)]]
      end
      client = FakeAppStoreConnectClient.new(app_store_versions: versions, review_submissions: [])
      manager = release_manager(client)

      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )

      renames = client.calls.select do |method, path, body|
        method == :patch && path.include?("appStoreVersions") &&
          body&.dig(:data, :attributes, :versionString) == "1.0.2"
      end
      created = client.calls.select { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
      assert_equal 2, renames.length, state
      assert_empty created, state
    end
  end

  def test_version_update_conflict_reconciles_an_already_changed_version
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      rename_error_status: 409,
      rename_mutates_before_error: true
    )
    manager = release_manager(client)

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    submitted = client.calls.count do |method, path, body|
      method == :patch && path.start_with?("/v1/reviewSubmissions/review-submission-") &&
        body.dig(:data, :attributes, :submitted) == true
    end
    assert_equal 2, submitted
  end

  def test_refused_version_change_stops_safely_and_rerun_recovers_rejected_versions
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      rename_error_status: 422
    )
    manager = release_manager(client)

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )
    end

    assert_match(/Apple returned HTTP 422/, error.message)
    assert_match(/still reports version 1\.0\.1 in DEVELOPER_REJECTED/, error.message)
    assert_match(/did not delete or create a version/, error.message)
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    cancellation_count = client.calls.count do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    assert_equal 2, cancellation_count
  end

  def test_replacement_waits_for_apple_to_confirm_the_canceled_version
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.2", state: "WAITING_FOR_REVIEW")]
    }
    submissions = [
      review_submission(
        platform: "IOS",
        version_id: "version-IOS-1.0.1",
        state: "WAITING_FOR_REVIEW"
      ),
      review_submission(
        platform: "MAC_OS",
        version_id: "version-MAC_OS-1.0.2",
        state: "WAITING_FOR_REVIEW"
      )
    ]
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      cancel_transition_reads: 1
    )
    sleeps = []
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    rename_index = client.calls.index do |method, path, body|
      method == :patch && path == "/v1/appStoreVersions/version-IOS-1.0.1" &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    end
    refute_nil rename_index
    confirmation_reads = client.calls.each_index.select do |index|
      method, path, = client.calls[index]
      index < rename_index && method == :get && path == "/v1/appStoreVersions/version-IOS-1.0.1"
    end
    assert_equal [10, 10], sleeps
    assert_operator confirmation_reads.length, :>=, 3
    assert_equal rename_index - 1, confirmation_reads.last
  end

  def test_rerun_does_not_repeat_a_cancellation_that_apple_is_completing
    %w[COMPLETING COMPLETE].each do |initial_submission_state|
      versions = {
        "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
        "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.2", state: "WAITING_FOR_REVIEW")]
      }
      submissions = [
        review_submission(
          platform: "IOS",
          version_id: "version-IOS-1.0.1",
          state: initial_submission_state
        ),
        review_submission(
          platform: "MAC_OS",
          version_id: "version-MAC_OS-1.0.2",
          state: "WAITING_FOR_REVIEW"
        )
      ]
      client = FakeAppStoreConnectClient.new(
        app_store_versions: versions,
        review_submissions: submissions
      )
      original_get = client.method(:get)
      version_reads = 0
      client.define_singleton_method(:get) do |path, query: {}|
        response = original_get.call(path, query: query)
        if path == "/v1/reviewSubmissions/old-review-IOS"
          response.fetch("data").fetch("attributes")["state"] = "COMPLETE"
        elsif path == "/v1/appStoreVersions/version-IOS-1.0.1"
          version_reads += 1
          if version_reads >= 3
            response.fetch("data").fetch("attributes")["appVersionState"] = "DEVELOPER_REJECTED"
          end
        end
        response
      end
      sleeps = []
      manager = AppStoreConnect::ReleaseManager.new(
        client: client,
        app_id: "6805117080",
        output_path: nil,
        summary_path: nil,
        sleeper: ->(seconds) { sleeps << seconds },
        monotonic_clock: -> { 0 }
      )

      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )

      refute cancellation_requested?(client), initial_submission_state
      assert_equal [10, 10], sleeps, initial_submission_state
    end
  end

  def test_invalid_target_state_prevents_every_cancellation
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.2", state: "REPLACED_WITH_NEW_VERSION")]
    }
    submissions = [
      review_submission(
        platform: "IOS",
        version_id: "version-IOS-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    ]
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = release_manager(client)

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )
    end

    assert_match(/cannot use this release workflow from states: MAC_OS=REPLACED_WITH_NEW_VERSION/, error.message)
    assert_match(/higher version number/, error.remediation)
    refute cancellation_requested?(client)
    assert_empty(client.calls.select { |method, path, _body| method == :post && path == "/v1/appStoreVersions" })
  end

  def test_missing_review_metadata_prevents_every_cancellation
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      review_notes: ""
    )
    manager = release_manager(client)

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )
    end

    assert_match(/App Store review notes are missing/, error.message)
    refute cancellation_requested?(client)
  end

  def test_missing_release_notes_file_prevents_every_cancellation
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = release_manager(client)

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        localization_paths: { "IOS" => { "en-US" => "/missing/release-notes.txt" } },
        create_versions: true,
        automatic_release: true
      )
    end

    assert_match(/IOS App Store release notes are missing for en-US/, error.message)
    refute cancellation_requested?(client)
  end

  def test_rerun_renames_versions_that_were_already_developer_rejected
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.1", state: "DEVELOPER_REJECTED")]]
    end
    client = FakeAppStoreConnectClient.new(app_store_versions: versions)
    manager = release_manager(client)

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    rename_calls = client.calls.select do |method, path, body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/version-(?:IOS|MAC_OS)-1\.0\.1\z}) &&
        body.dig(:data, :attributes, :versionString) == "1.0.2"
    end
    assert_equal 2, rename_calls.length
    refute cancellation_requested?(client)
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
  end

  def test_pending_release_can_be_canceled_through_its_completed_review_submission
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(
        platform: platform,
        version: "1.0.1",
        state: "PENDING_DEVELOPER_RELEASE"
      )]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.1",
        state: "COMPLETE"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    manager.prepare_app_store(
      version: "1.0.2",
      build_number: "714",
      submit: true,
      create_versions: true,
      automatic_release: true
    )

    cancellation_count = client.calls.count do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    assert_equal 2, cancellation_count
  end

  def test_approved_release_with_resubmission_history_cancels_its_latest_completed_review
    [false, true].each do |newest_first|
      versions = AppStoreConnect::PLATFORMS.to_h do |platform|
        [platform, [app_store_version(platform: platform, version: "1.0.3", state: "PENDING_DEVELOPER_RELEASE")]]
      end
      older = review_submission(platform: "IOS", version_id: "version-IOS-1.0.3", state: "COMPLETE")
      older["id"] = "earlier-review-IOS"
      older["attributes"]["submittedDate"] = "2026-09-18T06:59:02Z"
      newer = review_submission(platform: "IOS", version_id: "version-IOS-1.0.3", state: "COMPLETE")
      newer["id"] = "approved-review-IOS"
      newer["attributes"]["submittedDate"] = "2026-09-18T09:14:40Z"
      mac = review_submission(platform: "MAC_OS", version_id: "version-MAC_OS-1.0.3", state: "COMPLETE")
      mac["attributes"]["submittedDate"] = "2026-09-18T09:15:03Z"
      ios_history = newest_first ? [newer, older] : [older, newer]
      client = FakeAppStoreConnectClient.new(app_store_versions: versions, review_submissions: ios_history + [mac])
      manager = AppStoreConnect::ReleaseManager.new(
        client: client, app_id: "6805117080", output_path: nil, summary_path: nil,
        sleeper: ->(_seconds) {}, monotonic_clock: -> { 0 }
      )

      manager.prepare_app_store(
        version: "1.0.4", build_number: "714", submit: true, create_versions: true, automatic_release: true
      )

      cancellations = client.calls.filter_map do |method, path, body|
        path if method == :patch && body.dig(:data, :attributes, :canceled) == true
      end
      assert_equal ["/v1/reviewSubmissions/approved-review-IOS", "/v1/reviewSubmissions/old-review-MAC_OS"].sort,
                   cancellations.sort
      AppStoreConnect::PLATFORMS.each do |platform|
        assert client.calls.any? { |method, path, body|
          method == :patch && path == "/v1/appStoreVersions/version-#{platform}-1.0.3" &&
            body.dig(:data, :attributes, :versionString) == "1.0.4"
        }, "#{platform} must reuse its approved version record for 1.0.4"
      end
    end
  end

  def test_release_refuses_to_replace_a_newer_reviewed_version
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.1", state: "WAITING_FOR_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.3", state: "WAITING_FOR_REVIEW")]
    }
    submissions = versions.map do |platform, platform_versions|
      existing_version = platform_versions.fetch(0).dig("attributes", "versionString")
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-#{existing_version}",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(
        version: "1.0.2",
        build_number: "714",
        submit: true,
        create_versions: true,
        automatic_release: true
      )
    end

    assert_match(/1\.0\.3 cannot be superseded by 1\.0\.2/, error.message)
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
    cancellation_requested = client.calls.any? do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    refute cancellation_requested
  end

  def test_open_review_submission_rejects_another_app_version
    client = FakeAppStoreConnectClient.new(review_items: [{
      "id" => "existing-item",
      "relationships" => {
        "appStoreVersion" => { "data" => { "type" => "appStoreVersions", "id" => "other-version" } }
      }
    }])
    def client.collection(path, query: {})
      if path == "/v1/apps/6805117080/reviewSubmissions" && query["filter[state]"] == "READY_FOR_REVIEW"
        return [{ "id" => "open", "attributes" => { "state" => "READY_FOR_REVIEW" } }]
      end

      super
    end
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)
    end
    assert_match(/already contains another app version/, error.message)
  end

  def test_find_or_create_review_submission_creates_when_no_open_submission_exists
    submission = @manager.send(
      :find_or_create_review_submission,
      platform: "IOS",
      version_id: "version-IOS"
    )

    assert_equal "review-submission-IOS", submission.fetch("id")
    assert_equal 1, @client.calls.count { |method, path, _body| method == :post && path == "/v1/reviewSubmissions" }
  end

  def test_find_or_create_review_submission_reuses_ready_submission_without_post
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "READY_FOR_REVIEW")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    manager = release_manager(client)

    result = manager.send(
      :find_or_create_review_submission,
      platform: "IOS",
      version_id: "version-IOS"
    )

    assert_equal "old-review-IOS", result.fetch("id")
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/reviewSubmissions" }
  end

  def test_find_or_create_review_submission_cancels_same_version_rejected_submission_then_creates
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "UNRESOLVED_ISSUES")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    original_collection = client.method(:collection)
    original_patch = client.method(:patch)
    reads = 0
    client.define_singleton_method(:collection) do |path, query: {}|
      if path == "/v1/apps/6805117080/reviewSubmissions"
        reads += 1
        @review_submissions.first.fetch("attributes")["state"] = "COMPLETE" if reads == 2
      end
      original_collection.call(path, query: query)
    end
    client.define_singleton_method(:patch) do |path, body:|
      if body.dig(:data, :attributes, :canceled) == true
        @calls << [:patch, path, body]
        @review_submissions.first.fetch("attributes")["state"] = "COMPLETE"
        { "data" => @review_submissions.first }
      else
        original_patch.call(path, body: body)
      end
    end
    sleeps = []
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      monotonic_clock: -> { 0 }
    )

    result = manager.send(
      :find_or_create_review_submission,
      platform: "IOS",
      version_id: "version-IOS",
      poll_seconds: 3
    )

    assert_equal "review-submission-IOS", result.fetch("id")
    assert_equal [3], sleeps
    assert client.calls.any? { |method, path, body| method == :patch && path == "/v1/reviewSubmissions/old-review-IOS" && body.dig(:data, :attributes, :canceled) }
    assert_equal 1, client.calls.count { |method, path, _body| method == :post && path == "/v1/reviewSubmissions" }
  end

  def test_find_or_create_review_submission_rejects_different_version_without_cancel
    existing = review_submission(platform: "IOS", version_id: "other-version", state: "UNRESOLVED_ISSUES")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).send(
        :find_or_create_review_submission,
        platform: "IOS",
        version_id: "version-IOS"
      )
    end

    assert_equal :apple_state_conflict, error.category
    assert_includes error.remediation, "old-review-IOS"
    refute client.calls.any? { |method, _path, _body| method == :patch }
  end

  def test_find_or_create_review_submission_rejects_waiting_for_review_without_cancel
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "WAITING_FOR_REVIEW")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).send(
        :find_or_create_review_submission,
        platform: "IOS",
        version_id: "version-IOS"
      )
    end

    assert_equal :apple_state_conflict, error.category
    assert_includes error.remediation, "old-review-IOS"
    refute client.calls.any? { |method, _path, _body| method == :patch }
  end

  def test_find_or_create_review_submission_waits_for_canceling_without_patching
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "CANCELING")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    sleeps = []
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      monotonic_clock: -> { 0 }
    )
    result = nil
    client.define_singleton_method(:collection) do |path, query: {}|
      result = { "id" => "review-submission-IOS", "attributes" => { "platform" => "IOS", "state" => "READY_FOR_REVIEW" } } if path == "/v1/apps/6805117080/reviewSubmissions" && sleeps.any?
      result ? [result] : super(path, query: query)
    end

    submission = manager.send(:find_or_create_review_submission, platform: "IOS", version_id: "version-IOS", poll_seconds: 4)

    assert_equal "review-submission-IOS", submission.fetch("id")
    assert_equal [4], sleeps
    refute client.calls.any? { |method, _path, _body| method == :patch }
  end

  def test_find_or_create_review_submission_timeout_has_remediation
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "CANCELING")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).send(
        :find_or_create_review_submission,
        platform: "IOS",
        version_id: "version-IOS",
        timeout_seconds: 0
      )
    end

    assert_equal :apple_state_conflict, error.category
    assert_match(/still processing the cancellation/, error.remediation)
  end

  def test_find_or_create_review_submission_409_cancel_conflict_mentions_resubmit
    existing = review_submission(platform: "IOS", version_id: "version-IOS", state: "UNRESOLVED_ISSUES")
    client = FakeAppStoreConnectClient.new(review_submissions: [existing])
    original_patch = client.method(:patch)
    client.define_singleton_method(:patch) do |path, body:|
      if body.dig(:data, :attributes, :canceled) == true
        raise AppStoreConnect::APIError.new("still unresolved", status: 409, codes: ["STATE_ERROR"])
      end
      original_patch.call(path, body: body)
    end

    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).send(
        :find_or_create_review_submission,
        platform: "IOS",
        version_id: "version-IOS"
      )
    end

    assert_equal :apple_state_conflict, error.category
    assert_match(/Resubmit/, error.remediation)
  end

  def test_with_current_builds_retries_missing_builds_with_newly_resolved_builds
    builds = [{ "id" => "old" }]
    resolved = [{ "id" => "new" }]
    sleeps = []
    manager = AppStoreConnect::ReleaseManager.new(
      client: @client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(seconds) { sleeps << seconds }
    )
    manager.define_singleton_method(:require_valid_builds) { |version:, build_number:| resolved }
    attempts = 0
    result = manager.send(:with_current_builds, builds, version: "1.0.0", build_number: "714", wait_seconds: 6) do |current|
      attempts += 1
      raise AppStoreConnect::APIError.new("missing builds", status: 404) if attempts == 1

      current
    end

    assert_equal resolved, result
    assert_equal 2, attempts
    assert_equal [6], sleeps
  end

  def test_with_current_builds_retries_four_times_then_raises_resource_missing
    manager = release_manager(@client)
    manager.define_singleton_method(:require_valid_builds) { |version:, build_number:| [{ "id" => "new" }] }
    error = assert_raises(AppStoreConnect::Error) do
      manager.send(:with_current_builds, [{ "id" => "old" }], version: "1.0.0", build_number: "714") do |_current|
        raise AppStoreConnect::APIError.new("missing builds", status: 404)
      end
    end

    assert_equal :apple_resource_missing, error.category
    assert_match(/publish a release with a higher build number/, error.remediation)
  end

  def test_with_current_builds_reraises_a_non_build_404_unchanged
    manager = release_manager(@client)
    original = AppStoreConnect::APIError.new("missing app", status: 404)
    error = assert_raises(AppStoreConnect::APIError) do
      manager.send(:with_current_builds, [], version: "1.0.0", build_number: "714") { raise original }
    end

    assert_same original, error
  end

  def test_preflight_existing_target_states_rejects_replaced_mac_before_creating_missing_ios
    client = FakeAppStoreConnectClient.new(
      app_store_versions: {
        "IOS" => [],
        "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.0", state: "REPLACED_WITH_NEW_VERSION")]
      }
    )
    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).prepare_app_store(
        version: "1.0.0", build_number: "714", submit: true, create_versions: true
      )
    end

    assert_equal :release_state, error.category
    refute client.calls.any? { |method, path, _body| method == :post && path == "/v1/appStoreVersions" }
  end

  def test_add_version_to_review_submission_reports_foreign_version_and_remediation
    client = FakeAppStoreConnectClient.new(review_items: [{
      "id" => "foreign-item",
      "relationships" => { "appStoreVersion" => { "data" => { "id" => "foreign-version" } } }
    }])
    error = assert_raises(AppStoreConnect::Error) do
      release_manager(client).send(
        :add_version_to_review_submission,
        submission_id: "submission-1",
        version_id: "version-IOS"
      )
    end

    assert_includes error.message, "foreign-version"
    assert_includes error.remediation, "submission-1"
  end

  def test_resubmit_ignores_outdated_notes_when_state_matches_and_files_are_identical
    # SUBMITTED + matching notes ("Old notes" file vs default localizations),
    # WAITING_FOR_REVIEW 1.0.3 versions, submit:true → no writes/cancels + "release notes already match"
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "WAITING_FOR_REVIEW")]]
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      app_store_localizations: [
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-de-DE", "attributes" => { "locale" => "de-DE", "whatsNew" => "Old notes" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-en-US", "attributes" => { "locale" => "en-US", "whatsNew" => "Old notes" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-MAC_OS-1.0.3-de-DE", "attributes" => { "locale" => "de-DE", "whatsNew" => "Old notes" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-MAC_OS-1.0.3-en-US", "attributes" => { "locale" => "en-US", "whatsNew" => "Old notes" } }
      ]
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Old notes")
      end
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: true,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    assert_match(/Skipped IOS whatsNew update.*version 1\.0\.3 in WAITING_FOR_REVIEW.*release notes already match/, summary_content)
    assert_match(/Skipped MAC_OS whatsNew update.*version 1\.0\.3 in WAITING_FOR_REVIEW.*release notes already match/, summary_content)
    assert_empty(client.calls.select { |m, p, _| m == :post && p == "/v1/appStoreVersionLocalizations" })
    assert_empty(client.calls.select { |m, _, b| m == :patch && b.dig(:data, :attributes, :canceled) == true })
  ensure
    summary_file&.unlink
  end

  def test_resubmit_tolerates_whitespace_drift_in_stored_release_notes
    # Stored notes carry CRLF line endings and double spaces vs. the local
    # files; normalized comparison must treat them as matching and must not
    # cancel App Review for invisible differences.
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "WAITING_FOR_REVIEW")]]
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      app_store_localizations: [
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-de-DE", "attributes" => { "locale" => "de-DE", "whatsNew" => "Alte  Notizen\r\nzweite Zeile" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-en-US", "attributes" => { "locale" => "en-US", "whatsNew" => "Old\r\nnotes" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-MAC_OS-1.0.3-de-DE", "attributes" => { "locale" => "de-DE", "whatsNew" => "Alte  Notizen\r\nzweite Zeile" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-MAC_OS-1.0.3-en-US", "attributes" => { "locale" => "en-US", "whatsNew" => "Old\r\nnotes" } }
      ]
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      File.write("#{dir}/de-DE.md", "Alte Notizen\nzweite Zeile")
      File.write("#{dir}/en-US.md", "Old notes")
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: true,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    assert_match(/Skipped IOS whatsNew update.*version 1\.0\.3 in WAITING_FOR_REVIEW.*release notes already match/, summary_content)
    assert_match(/Skipped MAC_OS whatsNew update.*version 1\.0\.3 in WAITING_FOR_REVIEW.*release notes already match/, summary_content)
    assert_empty(client.calls.select { |m, p, _| m == :post && p == "/v1/appStoreVersionLocalizations" })
    assert_empty(client.calls.select { |m, _, b| m == :patch && b.dig(:data, :attributes, :canceled) == true })
  ensure
    summary_file&.unlink
  end

  def test_resubmit_cancels_when_only_one_locale_matches_on_submitted_version
    # partial match: de-DE matches, en-US differs → must still cancel-and-resubmit both locales
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.3",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      app_store_localizations: [
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-de-DE", "attributes" => { "locale" => "de-DE", "whatsNew" => "Matching de-DE notes" } },
        { "type" => "appStoreVersionLocalizations", "id" => "version-IOS-1.0.3-en-US", "attributes" => { "locale" => "en-US", "whatsNew" => "Different en-US notes" } }
      ],
      review_submissions: submissions
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      File.write("#{dir}/de-DE.md", "Matching de-DE notes")
      File.write("#{dir}/en-US.md", "Updated en-US notes")
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: true,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    # Still triggers cancel+resubmit because en-US differs
    assert_match(/Removed IOS 1\.0\.3 from App Review/, summary_content)
    cancellations = client.calls.select { |m, p, b| m == :patch && b.dig(:data, :attributes, :canceled) == true }
    assert_equal 1, cancellations.size
    submissions_post = client.calls.select { |m, p, _| m == :post && p == "/v1/reviewSubmissions" }
    assert_equal 1, submissions_post.size
  ensure
    summary_file&.unlink
  end

  def test_resubmit_cancels_and_re_submits_with_outdated_notes
    # outdated + submit:true + WAITING_FOR_REVIEW target with review_submission fixtures
    # version_id "version-#{platform}-1.0.3" → cancel patch + localization writes + review submission POSTs + submit patches
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.3",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Updated release notes for 1.0.3")
      end
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: true,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    # Should have cancel patches
    cancels = client.calls.select { |m, p, b| m == :patch && b.dig(:data, :attributes, :canceled) == true }
    assert_equal 2, cancels.size
    # Should have new review submissions
    submissions_post = client.calls.select { |m, p, _| m == :post && p == "/v1/reviewSubmissions" }
    assert_equal 2, submissions_post.size
  ensure
    summary_file&.unlink
  end

  def test_resubmit_skips_cancel_when_non_submit_and_differing_notes
    # non-submit + submitted + differing → no cancel + "not canceled because submission was not requested"
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "WAITING_FOR_REVIEW")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.3",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Different notes that would normally require cancel")
      end
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: false,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    summary_file.rewind
    summary_content = summary_file.read
    summary_file.close
    summary_file.unlink

    assert_match(/App Review was not canceled because submission was not requested/, summary_content)
    assert_empty(client.calls.select { |m, p, b| m == :patch && b.dig(:data, :attributes, :canceled) == true })
  ensure
    summary_file&.unlink
  end

  def test_resubmit_raises_hard_error_for_non_pre_acceptance_states
    # PENDING_DEVELOPER_RELEASE + differing + submit:true → raises "Apple cannot cancel App Review from that state"
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "PENDING_DEVELOPER_RELEASE")]]
    end
    client = FakeAppStoreConnectClient.new(app_store_versions: versions)
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      File.write("#{dir}/de-DE.md", "Notes requiring cancel")
      File.write("#{dir}/en-US.md", "Notes requiring cancel")
      error = assert_raises(AppStoreConnect::Error) do
        manager.prepare_app_store(
          version: "1.0.3",
          build_number: "715",
          submit: true,
          localization_paths: {
            "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
            "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
          }
        )
      end
      assert_match(/Apple cannot cancel App Review from that state/, error.message)
    end
  ensure
    summary_file&.unlink
  end

  def test_resubmit_preflight_blocks_mixed_states_before_any_cancellation
    # IOS is cancelable but MAC_OS sits in a post-acceptance state with
    # different notes: the release must fail before IOS loses its App Review.
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      state = platform == "IOS" ? "WAITING_FOR_REVIEW" : "PENDING_DEVELOPER_RELEASE"
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: state)]]
    end
    client = FakeAppStoreConnectClient.new(app_store_versions: versions)
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      File.write("#{dir}/de-DE.md", "Notes requiring cancel")
      File.write("#{dir}/en-US.md", "Notes requiring cancel")
      error = assert_raises(AppStoreConnect::Error) do
        manager.prepare_app_store(
          version: "1.0.3",
          build_number: "715",
          submit: true,
          localization_paths: {
            "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
            "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
          }
        )
      end
      assert_match(/MAC_OS.*Apple cannot cancel App Review from that state/, error.message)
      # No platform may lose its App Review because another platform cannot change notes.
      assert_empty(client.calls.select { |m, _, b| m == :patch && b.dig(:data, :attributes, :canceled) == true })
    end
  ensure
    summary_file&.unlink
  end

  def test_resubmit_handles_multiple_lock_conflicts_with_submit_true
    # conflicts:1 + transitions + submit:true + review_submissions in WAITING_FOR_REVIEW → cancel-and-resubmit both platforms
    # (2 cancellation patches, 2 POSTs, 2 submit patches)
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "PREPARE_FOR_SUBMISSION")]]
    end
    submissions = AppStoreConnect::PLATFORMS.map do |platform|
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-1.0.3",
        state: "WAITING_FOR_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions,
      localization_lock_conflicts: 1,
      localization_conflict_transitions_to_submitted: true
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Updated notes after conflict resolution")
      end
      manager.prepare_app_store(
        version: "1.0.3",
        build_number: "715",
        submit: true,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    # Should have 2 cancellation patches
    cancels = client.calls.select { |m, p, b| m == :patch && b.dig(:data, :attributes, :canceled) == true }
    assert_equal 2, cancels.size
    # Should have 2 new review submissions
    submissions_post = client.calls.select { |m, p, _| m == :post && p == "/v1/reviewSubmissions" }
    assert_equal 2, submissions_post.size
  ensure
    summary_file&.unlink
  end

  def test_resubmit_detects_lock_exhaustion_and_raises
    # exhaustion: conflicts:100, no transition, ticks advance by 50 each poll, no-op sleeper, submit:false
    # → raises /stayed locked in PREPARE_FOR_SUBMISSION.*300s/
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "PREPARE_FOR_SUBMISSION")]]
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      localization_lock_conflicts: 100
    )
    summary_file = Tempfile.new("release-summary")
    tick_count = 0
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_s) {},
      monotonic_clock: -> { tick_count; tick_count += 50 } # advances by 50 on each call
    )

    Dir.mktmpdir do |dir|
      File.write("#{dir}/de-DE.md", "Some notes")
      File.write("#{dir}/en-US.md", "Some notes")
      error = assert_raises(AppStoreConnect::Error) do
        manager.prepare_app_store(
          version: "1.0.3",
          build_number: "715",
          submit: false,
          localization_paths: {
            "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
            "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
          }
        )
      end
      assert_match(/stayed locked in PREPARE_FOR_SUBMISSION.*300s/, error.message)
    end
  ensure
    summary_file&.unlink
  end

  def test_resubmit_propagates_raw_api_error_for_wrong_codes
    # localization_lock_codes: ["ENTITY_ERROR"] → raw AppStoreConnect::APIError propagates
    versions = AppStoreConnect::PLATFORMS.to_h do |platform|
      [platform, [app_store_version(platform: platform, version: "1.0.3", state: "PREPARE_FOR_SUBMISSION")]]
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      localization_lock_conflicts: 1,
      localization_lock_codes: ["ENTITY_ERROR"]
    )
    summary_file = Tempfile.new("release-summary")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: summary_file.path,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    error = assert_raises(AppStoreConnect::APIError) do
      Dir.mktmpdir do |dir|
        %w[de-DE en-US].each do |locale|
          File.write("#{dir}/#{locale}.md", "Notes for lock propagation test")
        end
        manager.prepare_app_store(
          version: "1.0.3",
          build_number: "715",
          submit: true,
          localization_paths: {
            "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
            "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
          }
        )
      end
    end
    assert_match(/whatsNew/, error.message)
    assert_includes(error.codes, "ENTITY_ERROR")
  ensure
    summary_file&.unlink
  end

  def test_resubmit_same_version_in_review_requires_cancellation_and_build_update
    # Scenario: Rapid release - version 1.0.5 already IN_REVIEW (old build 714),
    # user submits 1.0.5 again with higher build (715). The workflow must:
    # (1) cancel the existing IN_REVIEW submission, (2) wait for DEVELOPER_REJECTED,
    # (3) attach the new build, (4) resubmit. This validates the Replace-in-Review
    # path for same-version-with-new-build scenarios.
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.5", state: "IN_REVIEW")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.5", state: "IN_REVIEW")]
    }
    submissions = versions.map do |platform, platform_versions|
      existing_version = platform_versions.fetch(0).dig("attributes", "versionString")
      review_submission(
        platform: platform,
        version_id: "version-#{platform}-#{existing_version}",
        state: "IN_REVIEW"
      )
    end
    client = FakeAppStoreConnectClient.new(
      app_store_versions: versions,
      review_submissions: submissions
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Bug fix release 1.0.5")
      end
      manager.prepare_app_store(
        version: "1.0.5",
        build_number: "715",
        submit: true,
        create_versions: false,
        localization_paths: {
          "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
          "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
        }
      )
    end

    # Verify cancellation was sent for both platforms
    cancellations = client.calls.select do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
    assert_equal 2, cancellations.length, "Expected 2 cancellations (iOS + macOS)"

    # Verify new build attachment to existing version
    build_attachments = client.calls.select do |method, path, _body|
      method == :patch && path.include?("appStoreVersions") && path.include?("/build")
    end
    assert_equal 2, build_attachments.length, "Expected 2 build attachments"
  end

  def test_resubmit_released_version_raises_error_without_auto_retry
    # Scenario: Version 1.0.4 already READY_FOR_SALE (released), user tries to
    # replace it with same version but higher build. The workflow must fail-fast
    # with a clear error message — Apple does not allow cancelling released
    # versions automatically. Manual intervention required via App Store Connect UI.
    versions = {
      "IOS" => [app_store_version(platform: "IOS", version: "1.0.4", state: "READY_FOR_SALE")],
      "MAC_OS" => [app_store_version(platform: "MAC_OS", version: "1.0.4", state: "READY_FOR_SALE")]
    }
    client = FakeAppStoreConnectClient.new(app_store_versions: versions)
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    Dir.mktmpdir do |dir|
      %w[de-DE en-US].each do |locale|
        File.write("#{dir}/#{locale}.md", "Hotfix release 1.0.4")
      end
      error = assert_raises(AppStoreConnect::Error) do
        manager.prepare_app_store(
          version: "1.0.4",
          build_number: "720",
          submit: true,
          create_versions: false,
          localization_paths: {
            "IOS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" },
            "MAC_OS" => { "de-DE" => "#{dir}/de-DE.md", "en-US" => "#{dir}/en-US.md" }
          }
        )
      end

      # Error message must indicate the state and inability to cancel
      assert_match(/1\.0\.4.*READY_FOR_SALE.*cannot.*cancel.*App Review/, error.message)

      # No cancellation or mutation attempts for released versions
      assert_empty(client.calls.select { |m, _p, b| m == :patch && b&.dig(:data, :attributes, :canceled) == true })
    end
  end

  private

  def release_manager(client)
    AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil,
      sleeper: ->(_seconds) {},
      monotonic_clock: -> { 0 }
    )
  end

  def cancellation_requested?(client)
    client.calls.any? do |method, _path, body|
      method == :patch && body.dig(:data, :attributes, :canceled) == true
    end
  end

  def app_store_version(platform:, version:, state:)
    {
      "type" => "appStoreVersions",
      "id" => "version-#{platform}-#{version}",
      "attributes" => {
        "platform" => platform,
        "versionString" => version,
        "appVersionState" => state,
        "releaseType" => "AFTER_APPROVAL"
      }
    }
  end

  def review_submission(platform:, version_id:, state:)
    {
      "type" => "reviewSubmissions",
      "id" => "old-review-#{platform}",
      "attributes" => { "platform" => platform, "state" => state },
      "relationships" => {
        "appStoreVersionForReview" => {
          "data" => { "type" => "appStoreVersions", "id" => version_id }
        }
      }
    }
  end

end

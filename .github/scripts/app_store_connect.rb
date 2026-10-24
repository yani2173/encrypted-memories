#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "date"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

module AppStoreConnect
  API_ROOT = "https://api.appstoreconnect.apple.com"
  IN_APP_PURCHASE_CONTRACT_PATH = File.expand_path(
    "../app-store-connect/in-app-purchases.json",
    __dir__
  ).freeze
  IN_APP_PURCHASE_ACTIVE_VERSION_STATES = %w[
    PREPARE_FOR_SUBMISSION READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW ACCEPTED APPROVED
  ].freeze
  IN_APP_PURCHASE_REVIEW_PRODUCT_STATES = %w[
    READY_TO_SUBMIT WAITING_FOR_REVIEW IN_REVIEW PENDING_BINARY_APPROVAL APPROVED
  ].freeze
  IN_APP_PURCHASE_SANDBOX_PRODUCT_STATES = %w[
    MISSING_METADATA READY_TO_SUBMIT WAITING_FOR_REVIEW IN_REVIEW PENDING_BINARY_APPROVAL APPROVED
  ].freeze
  PLATFORMS = %w[IOS MAC_OS].freeze
  REVIEWED_BUILD_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW APPROVED].freeze
  SUBMITTED_VERSION_STATES = %w[
    WAITING_FOR_EXPORT_COMPLIANCE WAITING_FOR_REVIEW IN_REVIEW
    PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE
    PROCESSING_FOR_DISTRIBUTION READY_FOR_DISTRIBUTION READY_FOR_SALE
  ].freeze
  SUPERSEDED_VERSION_STATES = %w[
    WAITING_FOR_EXPORT_COMPLIANCE WAITING_FOR_REVIEW IN_REVIEW
    PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE
  ].freeze
  # App Review ended these versions without approval. Apple keeps them editable: the owner
  # corrects metadata or attaches a new build and submits again. Their review submission stays
  # open in UNRESOLVED_ISSUES and must be settled before a new submission can exist.
  APPLE_REJECTED_VERSION_STATES = %w[REJECTED METADATA_REJECTED INVALID_BINARY].freeze
  EDITABLE_VERSION_STATES = (
    %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW DEVELOPER_REJECTED] + APPLE_REJECTED_VERSION_STATES
  ).freeze
  # One review submission per platform can be open. These states block a new submission.
  OPEN_REVIEW_SUBMISSION_STATES = %w[
    READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES CANCELING COMPLETING
  ].freeze
  CANCELABLE_REVIEW_SUBMISSION_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETE].freeze
  TRANSITIONAL_REVIEW_SUBMISSION_STATES = %w[CANCELING COMPLETING].freeze
  PRE_ACCEPTANCE_VERSION_STATES = %w[
    WAITING_FOR_EXPORT_COMPLIANCE WAITING_FOR_REVIEW IN_REVIEW
  ].freeze
  WHATS_NEW_LOCK_TIMEOUT_SECONDS = 300
  WHATS_NEW_LOCK_POLL_SECONDS = 10
  RELEASE_NOTE_RESUBMIT_LIMIT = 2
  APP_VERSION_PATTERN = /\A[0-9]+\.[0-9]+\.[0-9]+\z/

  class Error < StandardError
    attr_reader :remediation, :category

    def initialize(message = nil, remediation: nil, category: nil)
      super(message)
      @remediation = remediation
      @category = category
    end
  end
  class APIError < Error
    attr_reader :status, :codes

    def initialize(message, status:, codes: [], remediation: nil, category: nil)
      super(message, remediation: remediation, category: category)
      @status = status
      @codes = codes.freeze
    end
  end
  class TransportError < Error; end

  module_function

  def failure_report(error)
    category, remediation, rerun_safe = classify_failure(error)
    {
      category: error.respond_to?(:category) && error.category || category,
      cause: error.message.to_s,
      remediation: error.respond_to?(:remediation) && error.remediation || remediation,
      rerun_safe: rerun_safe
    }
  end

  def classify_failure(error)
    if error.is_a?(TransportError)
      [
        :apple_or_network_outage,
        "check https://developer.apple.com/system-status/ and the runner network, then re-run the failed jobs.",
        true
      ]
    elsif error.is_a?(APIError)
      case error.status
      when 401, 403
        [
          :credentials,
          "verify the App Store Connect API key secrets (APP_STORE_CONNECT_ISSUER_ID, " \
            "APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_PRIVATE_KEY_BASE64), that the key is not revoked, " \
            "and that it has the App Manager role; also check for a pending Apple agreement in App Store Connect.",
          true
        ]
      when 429
        [:rate_limit, "Wait for Apple's rate limit to clear, then re-run the failed jobs.", true]
      when 500..599
        [:apple_outage, "Check https://developer.apple.com/system-status/, then re-run the failed jobs.", true]
      when 409
        [
          :apple_state_conflict,
          "open the named version in App Store Connect, compare its state with the message, resolve it, then re-run.",
          true
        ]
      when 404
        [:apple_resource_missing, "verify the named App Store Connect resource, then re-run the failed jobs.", false]
      else
        [
          :request_rejected,
          "read the App Store Connect response, correct the request, then re-run the failed jobs.",
          false
        ]
      end
    elsif error.message.to_s.start_with?("Missing ")
      missing = error.message.to_s.delete_prefix("Missing ")
      remediation = if missing.start_with?("--")
                      "Provide the required CLI option #{missing}, then re-run the failed jobs."
                    else
                      "Set the repository secret #{missing}, then re-run the failed jobs."
                    end
      [:configuration, remediation, false]
    else
      [
        :release_state,
        "Read the cause, correct the named App Store Connect or GitHub release state, then re-run the failed jobs. " \
          "The workflow is idempotent.",
        false
      ]
    end
  end

  def base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def fixed_width_integer(value)
    hex = value.to_i.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    bytes = [hex].pack("H*")
    raise Error, "Invalid ES256 signature" if bytes.bytesize > 32

    ("\0" * (32 - bytes.bytesize)) + bytes
  end

  def jwt(issuer_id:, key_id:, private_key:, now: Time.now.to_i)
    header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
    claims = base64url(JSON.generate(iss: issuer_id, iat: now, exp: now + 1_200, aud: "appstoreconnect-v1"))
    signing_input = "#{header}.#{claims}"
    key = OpenSSL::PKey.read(private_key)
    components = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest.new("SHA256"), signing_input)).value
    raise Error, "Invalid ES256 signature" unless components.length == 2

    signature = components.map { |component| fixed_width_integer(component.value) }.join
    "#{signing_input}.#{base64url(signature)}"
  end

  def build_filters(app_id:, version:, build_number:, platform:)
    {
      "filter[app]" => app_id,
      "filter[version]" => build_number,
      "filter[preReleaseVersion.version]" => version,
      "filter[preReleaseVersion.platform]" => platform,
      "filter[buildAudienceType]" => "APP_STORE_ELIGIBLE",
      "limit" => "10"
    }
  end

  def build_history_filters(app_id:, platform:, version: nil)
    filters = {
      "filter[app]" => app_id,
      "filter[preReleaseVersion.platform]" => platform,
      "filter[buildAudienceType]" => "APP_STORE_ELIGIBLE",
      "fields[builds]" => "version",
      "limit" => "200"
    }
    filters["filter[preReleaseVersion.version]"] = version if version
    filters
  end

  def beta_group_payload(app_id:, name:, internal:)
    {
      data: {
        type: "betaGroups",
        attributes: {
          name: name,
          isInternalGroup: internal,
          feedbackEnabled: true,
          hasAccessToAllBuilds: false
        },
        relationships: {
          app: { data: { type: "apps", id: app_id } }
        }
      }
    }
  end

  def beta_group_builds_payload(build_ids)
    { data: build_ids.map { |id| { type: "builds", id: id } } }
  end

  def beta_review_payload(build_id)
    {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: build_id } } }
      }
    }
  end

  def app_store_build_payload(build_id)
    { data: { type: "builds", id: build_id } }
  end

  def app_store_version_payload(app_id:, platform:, version:)
    {
      data: {
        type: "appStoreVersions",
        attributes: {
          platform: platform,
          versionString: version,
          releaseType: "AFTER_APPROVAL"
        },
        relationships: {
          app: { data: { type: "apps", id: app_id } }
        }
      }
    }
  end

  def automatic_release_payload(version_id)
    {
      data: {
        type: "appStoreVersions",
        id: version_id,
        attributes: { releaseType: "AFTER_APPROVAL" }
      }
    }
  end

  def app_store_version_number_payload(version_id:, version:)
    {
      data: {
        type: "appStoreVersions",
        id: version_id,
        attributes: { versionString: version }
      }
    }
  end

  def app_store_localization_payload(version_id:, locale:, whats_new:)
    {
      data: {
        type: "appStoreVersionLocalizations",
        attributes: { locale: locale, whatsNew: whats_new },
        relationships: {
          appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
        }
      }
    }
  end

  def app_store_localization_update_payload(localization_id:, whats_new:)
    {
      data: {
        type: "appStoreVersionLocalizations",
        id: localization_id,
        attributes: { whatsNew: whats_new }
      }
    }
  end

  def review_submission_payload(app_id:, platform:)
    {
      data: {
        type: "reviewSubmissions",
        attributes: { platform: platform },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  end

  def review_item_payload(submission_id:, version_id:)
    {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
          appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
        }
      }
    }
  end

  def submit_review_payload(submission_id)
    {
      data: {
        type: "reviewSubmissions",
        id: submission_id,
        attributes: { submitted: true }
      }
    }
  end

  def cancel_review_payload(submission_id)
    {
      data: {
        type: "reviewSubmissions",
        id: submission_id,
        attributes: { canceled: true }
      }
    }
  end

  class Client
    def initialize(issuer_id:, key_id:, private_key:, sleeper: ->(seconds) { sleep(seconds) })
      @issuer_id = issuer_id
      @key_id = key_id
      @private_key = private_key
      @sleeper = sleeper
    end

    def get(path, query: {})
      request(:get, path, query: query)
    end

    def post(path, body:)
      request(:post, path, body: body)
    end

    def patch(path, body:)
      request(:patch, path, body: body)
    end

    def collection(path, query: {})
      resources = []
      next_url = with_query(path, query)
      pages = 0

      while next_url
        pages += 1
        raise Error, "App Store Connect pagination exceeded 20 pages" if pages > 20

        response = request(:get, next_url)
        resources.concat(response.fetch("data"))
        next_url = response.dig("links", "next")
      end
      resources
    end

    private

    def with_query(path, query)
      return path if query.empty?

      separator = path.include?("?") ? "&" : "?"
      "#{path}#{separator}#{URI.encode_www_form(query)}"
    end

    def request(method, path, query: {}, body: nil)
      uri = path.start_with?("http") ? URI(path) : URI("#{API_ROOT}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      attempts = 0
      unauthorized_retries = 0

      loop do
        attempts += 1
        begin
          request = request_class(method).new(uri)
          request["Authorization"] = "Bearer #{token}"
          request["Accept"] = "application/json"
          if body
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(body)
          end

          response = Net::HTTP.start(
            uri.hostname,
            uri.port,
            use_ssl: true,
            open_timeout: 15,
            read_timeout: 60
          ) { |http| http.request(request) }
        rescue Timeout::Error, SocketError, EOFError, SystemCallError, OpenSSL::SSL::SSLError => error
          unless retryable_exception?(method, error) && attempts < 6
            raise TransportError, "App Store Connect transport failed: #{error.class}"
          end

          retry_request(method, uri, attempts, error.class.name, nil)
          next
        end

        if response.is_a?(Net::HTTPSuccess)
          return {} if response.body.nil? || response.body.empty?

          return JSON.parse(response.body)
        end

        if response.code.to_i == 401 && unauthorized_retries.zero? && attempts < 6
          unauthorized_retries += 1
          retry_request(method, uri, attempts, "HTTP 401", response)
          next
        end

        if retryable?(method, response) && attempts < 6
          retry_request(method, uri, attempts, "HTTP #{response.code}", response)
          next
        end

        raise api_error(response)
      end
    rescue JSON::ParserError
      raise Error, "App Store Connect returned invalid JSON"
    rescue OpenSSL::PKey::PKeyError
      raise Error, "The App Store Connect private key is invalid"
    end

    def token
      AppStoreConnect.jwt(
        issuer_id: @issuer_id,
        key_id: @key_id,
        private_key: @private_key
      )
    end

    def request_class(method)
      { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    end

    def retryable?(method, response)
      status = response.code.to_i
      # Apple rejects a rate-limited request before it applies it. Every other POST response,
      # including 503, leaves the outcome unknown, and a second POST could duplicate a resource.
      return true if status == 429
      return false if method == :post

      status >= 500 && status <= 599
    end

    def retryable_exception?(method, error)
      return false unless [Timeout::Error, SocketError, EOFError, SystemCallError, OpenSSL::SSL::SSLError].any? do |klass|
        error.is_a?(klass)
      end

      return true unless method == :post

      [Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH].any? do |klass|
        error.is_a?(klass)
      end
    end

    def retry_request(method, uri, attempt, reason, response)
      wait = retry_wait(attempt, response)
      puts "Retrying #{method.to_s.upcase} #{uri.path} (#{reason}) attempt #{attempt}/6 wait #{wait}s"
      @sleeper.call(wait)
    end

    def retry_wait(attempt, response)
      retry_after = response && response["Retry-After"]
      return [[retry_after.to_i, 0].max, 120].min if retry_after && retry_after.match?(/\A\d+\z/)

      if retry_after && !retry_after.empty?
        begin
          seconds = (Time.httpdate(retry_after) - Time.now).ceil
          return [[seconds, 0].max, 120].min
        rescue ArgumentError
          # Fall back to exponential backoff for an invalid Retry-After value.
        end
      end

      [2**attempt, 120].min
    end

    def api_error(response)
      errors = JSON.parse(response.body.to_s).fetch("errors", [])
      details = errors.filter_map do |error|
        [error["code"], error["title"], error["detail"]].compact.join(": ")
      end
      detail = details.empty? ? "No error detail was returned" : details.join("; ")
      APIError.new(
        "App Store Connect returned HTTP #{response.code}: #{detail}",
        status: response.code.to_i,
        codes: errors.filter_map { |error| error["code"] }
      )
    rescue JSON::ParserError
      APIError.new(
        "App Store Connect returned HTTP #{response.code} with an unreadable error response",
        status: response.code.to_i
      )
    end
  end

  class ReleaseManager
    def initialize(
      client:,
      app_id:,
      output_path: ENV["GITHUB_OUTPUT"],
      summary_path: ENV["GITHUB_STEP_SUMMARY"],
      in_app_purchase_contract_path: IN_APP_PURCHASE_CONTRACT_PATH,
      sleeper: ->(seconds) { sleep(seconds) },
      monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @client = client
      @app_id = app_id
      @output_path = output_path
      @summary_path = summary_path
      @in_app_purchase_contract_path = in_app_purchase_contract_path
      @sleeper = sleeper
      @monotonic_clock = monotonic_clock
    end

    def validate_build_number(version:, build_number:)
      candidate = normalized_build_number(build_number)
      PLATFORMS.each do |platform|
        existing = find_build(platform: platform, version: version, build_number: build_number)
        if existing
          state = existing.dig("attributes", "processingState") || "UNKNOWN"
          raise Error, "Apple already rejected #{platform} build #{version} (#{build_number})" if
            %w[FAILED INVALID].include?(state)

          next
        end

        comparison_version = platform == "IOS" ? version : nil
        highest = highest_build_number(platform: platform, version: comparison_version)
        next unless highest
        next if compare_build_numbers(candidate, highest).positive?

        scope = platform == "IOS" ? "for version #{version}" : "across all macOS versions"
        raise Error,
              "#{platform} build #{build_number} must be greater than existing build #{highest} #{scope}"
      end
      append_summary("Validated Apple build number #{build_number} for iOS and macOS.")
      true
    end

    def inspect_build(platform:, version:, build_number:)
      build = find_build(platform: platform, version: version, build_number: build_number)
      state = build&.dig("attributes", "processingState") || "MISSING"
      write_output("exists", (!build.nil?).to_s)
      write_output("processing_state", state)
      write_output("build_id", build&.fetch("id", "").to_s)
      puts "#{platform} #{version} (#{build_number}): #{state}"
      build
    end

    def wait_for_builds(version:, build_number:, timeout_seconds: 2_700, poll_seconds: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        builds = PLATFORMS.to_h do |platform|
          [platform, find_build(platform: platform, version: version, build_number: build_number)]
        end

        failures = builds.each_with_object([]) do |(platform, build), result|
          state = build&.dig("attributes", "processingState")
          result << "#{platform}=#{state}" if %w[FAILED INVALID].include?(state)
        end
        raise Error, "Apple rejected build processing: #{failures.join(", ")}" unless failures.empty?

        if builds.values.all? { |build| build&.dig("attributes", "processingState") == "VALID" }
          builds.each_value { |build| validate_export_compliance(build) }
          append_summary("Both App Store Connect builds are processed and valid.")
          return builds
        end

        states = builds.map do |platform, build|
          "#{platform}=#{build&.dig("attributes", "processingState") || "MISSING"}"
        end
        if monotonic_time >= deadline
          raise Error.new(
            "Timed out while Apple processed builds: #{states.join(", ")}",
            remediation: "Apple is still processing. Open App Store Connect > TestFlight and check the build. " \
              "Re-run the failed jobs later; the uploaded build is reused. If processing exceeds 24 hours, " \
              "contact Apple Developer Support."
          )
        end

        puts "Waiting for App Store Connect processing: #{states.join(", ")}"
        sleep(poll_seconds)
      end
    end

    def distribute_internal(version:, build_number:, group_name: nil, localization_paths: {})
      builds = require_valid_builds(version: version, build_number: build_number)
      group = find_or_create_group(name: group_name, internal: true)
      disable_mobile_builds_on_other_platforms(group)
      with_current_builds(builds, version: version, build_number: build_number) do |current|
        current.each do |platform, build|
          upsert_build_localizations(build.fetch("id"), localization_paths.fetch(platform, {}))
        end
        add_builds_to_group(group.fetch("id"), current.values.map { |build| build.fetch("id") })
      end
      append_summary("Distributed #{version} (#{build_number}) to internal group #{group.dig("attributes", "name")}.")
    end

    def distribute_external(version:, build_number:, group_name:, localization_paths:)
      builds = require_valid_builds(version: version, build_number: build_number)
      validate_in_app_purchase_sandbox
      validate_beta_app_localizations
      validate_beta_review_details
      unless beta_groups.any? { |group| group.dig("attributes", "isInternalGroup") == true }
        raise Error, "Create an internal TestFlight group before distributing to external testers"
      end
      # An external beta is always an internal beta, too. A stable release reaches no internal group on its own.
      internal_groups = beta_groups.select { |candidate| candidate.dig("attributes", "isInternalGroup") == true }
      if internal_groups.length > 1
        names = internal_groups.map { |candidate| candidate.dig("attributes", "name") }.compact.join(", ")
        raise Error, "External TestFlight needs exactly one internal TestFlight group; found #{names}"
      end
      internal_group = internal_groups.first
      group = find_or_create_group(name: group_name, internal: false)
      disable_mobile_builds_on_other_platforms(internal_group)
      disable_mobile_builds_on_other_platforms(group)

      with_current_builds(builds, version: version, build_number: build_number) do |current|
        current.each do |platform, build|
          upsert_build_localizations(build.fetch("id"), localization_paths.fetch(platform, {}))
        end
        build_ids = current.values.map { |build| build.fetch("id") }
        add_builds_to_group(internal_group.fetch("id"), build_ids)
        add_builds_to_group(group.fetch("id"), build_ids)
        current.each_value { |build| submit_beta_review(build) }
      end
      append_summary("Submitted #{version} (#{build_number}) for external TestFlight testing in #{group_name}.")
      enable_public_link(group)
    end

    # Testers join the external group through its public link, which the README names. A refused change leaves the
    # submitted beta intact; a later run enables the link again.
    def enable_public_link(group)
      attributes = group.fetch("attributes", {})
      link = attributes["publicLink"] if attributes["publicLinkEnabled"] == true
      unless link
        response = @client.patch(
          "/v1/betaGroups/#{group.fetch("id")}",
          body: { data: { type: "betaGroups", id: group.fetch("id"), attributes: { publicLinkEnabled: true } } }
        )
        link = response&.dig("data", "attributes", "publicLink")
      end
      if link.to_s.empty?
        append_summary("Apple returned no public TestFlight link yet. Run this workflow again after Beta App Review.")
      else
        write_output("public_link", link)
        append_summary("Public TestFlight link: #{link}")
      end
    rescue Error => error
      advice =
        if error.is_a?(APIError) && [409, 422].include?(error.status)
          "Run this workflow again after Beta App Review approves the build."
        else
          "Check the API key role and the external group in App Store Connect, then run this workflow again."
        end
      append_summary("The beta was submitted, but the public TestFlight link could not be enabled: #{error.message} #{advice}")
    end

    # Apple can list a build and still answer HTTP 404 for its id for a short time, and Apple
    # replaces the build record when the same build number is processed again (run 34993650537).
    # Every operation in the block tolerates repetition (upserts, group membership, and a
    # reconciled beta review submission), so the block runs again with newly resolved build ids. A build that stays missing is an owner decision, not a retry case.
    def with_current_builds(builds, version:, build_number:, attempts: 4, wait_seconds: 20)
      attempt = 0
      begin
        attempt += 1
        yield builds
      rescue APIError => error
        raise unless error.status == 404 && error.message.include?("builds")

        if attempt >= attempts
          raise Error.new(
            "Apple no longer returns build #{version} (#{build_number}): #{error.message}",
            category: :apple_resource_missing,
            remediation: "Open App Store Connect > TestFlight and check build #{build_number} on both " \
                         "platforms. If Apple removed or expired it, publish a release with a higher " \
                         "build number. If it is listed, re-run the failed jobs."
          )
        end
        puts "Apple returned HTTP 404 for a listed build; resolving the build ids again " \
             "(attempt #{attempt} of #{attempts})."
        @sleeper.call(wait_seconds)
        builds = require_valid_builds(version: version, build_number: build_number)
        retry
      end
    end

    def prepare_app_store(
      version:,
      build_number:,
      submit: false,
      localization_paths: {},
      create_versions: false,
      automatic_release: false
    )
      builds = require_valid_builds(version: version, build_number: build_number)
      validate_in_app_purchases(require_approved_products: submit)
      versions = if submit
                   resolve_app_store_versions_for_submission(
                     version: version,
                     builds: builds,
                     localization_paths: localization_paths,
                     create_versions: create_versions,
                     automatic_release: automatic_release
                   )
                 else
                   PLATFORMS.to_h do |platform|
                     app_store_version = if create_versions
                                           find_or_create_app_store_version(platform: platform, version: version)
                                         else
                                           require_app_store_version(platform: platform, version: version)
                                         end
                     [platform, app_store_version]
                   end
                 end
      states = versions.transform_values { |item| version_state(item) }
      invalid = states.reject do |_platform, state|
        SUBMITTED_VERSION_STATES.include?(state) || EDITABLE_VERSION_STATES.include?(state)
      end
      unless invalid.empty?
        raise Error.new(
          "App versions cannot use this release workflow from states: " \
          "#{invalid.map { |key, value| "#{key}=#{value}" }.join(", ")}",
          category: :release_state,
          remediation: unusable_version_state_remediation
        )
      end

      # Both platforms must pass the review-details preflight before any release
      # note synchronization may cancel a running App Review (see PROJECT-TRAPS:
      # stable-release-review-notes-preflight). Review details are keyed by the
      # immutable version id, so validating the pre-sync snapshot is equivalent.
      validate_app_store_review_details(versions)
      preflight_release_note_changes!(versions, localization_paths, submit: submit)

      versions.each do |platform, app_store_version|
        state = states.fetch(platform)
        ensure_automatic_release(app_store_version, platform: platform, state: state) if automatic_release

        # Apple locks whatsNew once a version enters any SUBMITTED state; synchronize
        # release notes for editable versions, and decide on skip/cancel/resubmit otherwise.
        refreshed = synchronize_app_store_release_notes(
          platform: platform,
          app_store_version: app_store_version,
          version: version,
          localization_paths: localization_paths.fetch(platform, {}),
          submit: submit
        )
        next if refreshed.nil?

        versions[platform] = refreshed
        states[platform] = version_state(refreshed)
      end

      versions.each do |platform, app_store_version|
        build_id = builds.fetch(platform).fetch("id")
        if SUBMITTED_VERSION_STATES.include?(states.fetch(platform))
          require_attached_build(app_store_version.fetch("id"), build_id)
        else
          attach_build(app_store_version.fetch("id"), build_id)
        end
      end

      unless submit
        append_summary("Attached both #{version} (#{build_number}) builds. App Review was not started.")
        return
      end

      if states.values.all? { |state| SUBMITTED_VERSION_STATES.include?(state) }
        append_summary("Both app versions are already submitted or approved.")
        return
      end

      versions.each do |platform, app_store_version|
        next if SUBMITTED_VERSION_STATES.include?(states.fetch(platform))

        submission = find_or_create_review_submission(
          platform: platform,
          version_id: app_store_version.fetch("id")
        )
        add_version_to_review_submission(
          submission_id: submission.fetch("id"),
          version_id: app_store_version.fetch("id")
        )
        @client.patch(
          "/v1/reviewSubmissions/#{submission.fetch("id")}",
          body: AppStoreConnect.submit_review_payload(submission.fetch("id"))
        )
      end
      append_summary("Submitted both #{version} (#{build_number}) app versions to App Review.")
    end

    def validate_in_app_purchase_sandbox
      product_count = validate_in_app_purchase_contract(require_review_metadata: false)
      append_summary(
        "#{product_count} configured in-app purchases have sandbox-ready App Store Connect metadata."
      )
      true
    rescue Errno::ENOENT, JSON::ParserError, KeyError => error
      raise Error, "Invalid in-app purchase contract: #{error.message}"
    end

    def validate_in_app_purchases(require_approved_products: false)
      product_count = validate_in_app_purchase_contract(
        require_review_metadata: true,
        require_approved_products: require_approved_products
      )
      append_summary(
        "#{product_count} configured in-app purchases match the App Store Connect review contract."
      )
      true
    rescue Errno::ENOENT, JSON::ParserError, KeyError => error
      raise Error, "Invalid in-app purchase contract: #{error.message}"
    end

    private

    def validate_in_app_purchase_contract(require_review_metadata:, require_approved_products: false)
      contract = JSON.parse(File.read(@in_app_purchase_contract_path, encoding: "UTF-8"))
      expected_products = contract.fetch("products")
      expected_review_note = normalized_text(contract.fetch("reviewNote"))
      required_territories = contract.fetch("requiredTerritories")
      allowed_product_states = if require_review_metadata
                                 IN_APP_PURCHASE_REVIEW_PRODUCT_STATES
                               else
                                 IN_APP_PURCHASE_SANDBOX_PRODUCT_STATES
                               end
      errors = []
      validate_in_app_purchase_bundle_identifier(contract.fetch("bundleIdentifier"), errors)
      capability_valid = validate_in_app_purchase_capability(contract.fetch("bundleIdentifier"), errors)
      raise Error, "In-app purchase preflight failed: #{errors.join('; ')}" unless capability_valid

      products = @client.collection(
        "/v1/apps/#{@app_id}/inAppPurchasesV2",
        query: {
          "fields[inAppPurchases]" => "name,productId,inAppPurchaseType,state,reviewNote",
          "limit" => "200"
        }
      )
      products_by_id = products.group_by { |product| product.dig("attributes", "productId") }

      expected_products.each do |expected|
        product_id = expected.fetch("productId")
        matches = products_by_id.fetch(product_id, [])
        if matches.empty?
          errors << "#{product_id} is missing"
          next
        end
        if matches.length > 1
          errors << "#{product_id} exists more than once"
          next
        end

        product = matches.first
        attributes = product.fetch("attributes")
        errors << "#{product_id} has reference name #{attributes['name'].inspect}" unless
          attributes["name"] == expected.fetch("referenceName")
        errors << "#{product_id} has type #{attributes['inAppPurchaseType'].inspect}" unless
          attributes["inAppPurchaseType"] == expected.fetch("type")
        product_state = attributes["state"]
        if require_approved_products && product_state != "APPROVED"
          errors << "#{product_id} has product state #{product_state.inspect}; " \
                    "automatic submission requires APPROVED products"
        elsif !allowed_product_states.include?(product_state)
          errors << "#{product_id} has product state #{product_state.inspect}"
        end
        if require_review_metadata
          errors << "#{product_id} has an unexpected review note" unless
            normalized_text(attributes["reviewNote"]) == expected_review_note
        end

        validate_in_app_purchase_metadata(
          product,
          expected,
          errors,
          required_territories: required_territories,
          require_review_metadata: require_review_metadata
        )
      end

      raise Error, "In-app purchase preflight failed: #{errors.join('; ')}" unless errors.empty?

      expected_products.length
    end

    def validate_in_app_purchase_bundle_identifier(expected_identifier, errors)
      app = @client.get(
        "/v1/apps/#{@app_id}",
        query: { "fields[apps]" => "bundleId" }
      )
      actual_identifier = app.dig("data", "attributes", "bundleId")
      return if actual_identifier == expected_identifier

      errors << "app has bundle identifier #{actual_identifier.inspect}; expected #{expected_identifier.inspect}"
    end

    def validate_in_app_purchase_capability(expected_identifier, errors)
      bundle_ids = @client.collection(
        "/v1/bundleIds",
        query: {
          "filter[identifier]" => expected_identifier,
          "fields[bundleIds]" => "identifier,platform",
          "limit" => "200"
        }
      ).select do |bundle_id|
        bundle_id.dig("attributes", "identifier") == expected_identifier
      end

      if bundle_ids.empty?
        errors << "registered bundle ID #{expected_identifier.inspect} is missing"
        return false
      end
      if bundle_ids.length > 1
        errors << "registered bundle ID #{expected_identifier.inspect} is ambiguous"
        return false
      end

      bundle_id_resource_id = bundle_ids.first["id"].to_s
      if bundle_id_resource_id.empty?
        errors << "registered bundle ID #{expected_identifier.inspect} has no resource ID"
        return false
      end

      capabilities = @client.collection(
        "/v1/bundleIds/#{bundle_id_resource_id}/bundleIdCapabilities",
        query: {
          "fields[bundleIdCapabilities]" => "capabilityType"
        }
      )
      if capabilities.any? do |capability|
        capability.dig("attributes", "capabilityType") == "IN_APP_PURCHASE"
      end
        puts "Registered bundle ID #{expected_identifier} enables In-App Purchase."
        return true
      end

      errors << "registered bundle ID #{expected_identifier.inspect} does not enable In-App Purchase"
      false
    rescue TransportError => error
      errors << "registered bundle ID capabilities could not be read: #{error.message}"
      false
    end

    def validate_in_app_purchase_metadata(
      product,
      expected,
      errors,
      required_territories:,
      require_review_metadata:
    )
      product_id = expected.fetch("productId")
      version = current_in_app_purchase_version(product, product_id, errors)
      validate_in_app_purchase_localizations(
        version,
        expected.fetch("localizations"),
        product_id,
        errors
      ) if version

      validate_in_app_purchase_price(product, product_id, errors)
      validate_in_app_purchase_availability(product, product_id, required_territories, errors)
      validate_in_app_purchase_review_screenshot(product, product_id, errors) if require_review_metadata
    end

    def current_in_app_purchase_version(product, product_id, errors)
      versions = @client.collection(
        "/v2/inAppPurchases/#{product.fetch('id')}/versions",
        query: {
          "fields[inAppPurchaseVersions]" => "version,state",
          "limit" => "200"
        }
      )
      if versions.empty?
        errors << "#{product_id} has no metadata version"
        return nil
      end

      latest = versions.max_by do |version|
        Integer(version.dig("attributes", "version"), exception: false) || -1
      end
      state = latest.dig("attributes", "state")
      unless IN_APP_PURCHASE_ACTIVE_VERSION_STATES.include?(state)
        errors << "#{product_id} latest metadata version has state #{state.inspect}"
        return nil
      end
      latest
    end

    def validate_in_app_purchase_localizations(version, expected_localizations, product_id, errors)
      localization_resources = @client.collection(
        "/v1/inAppPurchaseVersions/#{version.fetch('id')}/localizations",
        query: {
          "fields[inAppPurchaseLocalizations]" => "name,locale",
          "limit" => "200"
        }
      )
      localizations = localization_resources.to_h do |item|
        [item.dig("attributes", "locale"), item.fetch("attributes")]
      end

      expected_localizations.each do |locale, expected_localization|
        actual = localizations[locale]
        unless actual
          errors << "#{product_id} has no #{locale} localization"
          next
        end
        next if actual["name"] == expected_localization.fetch("name")

        errors << "#{product_id} #{locale} name is #{actual['name'].inspect}"
      end
    end

    def validate_in_app_purchase_price(product, product_id, errors)
      schedule = @client.get(
        "/v2/inAppPurchases/#{product.fetch('id')}/iapPriceSchedule",
        query: { "fields[inAppPurchasePriceSchedules]" => "manualPrices" }
      )
      prices = @client.collection(
        "/v1/inAppPurchasePriceSchedules/#{schedule.fetch('data').fetch('id')}/manualPrices",
        query: {
          "fields[inAppPurchasePrices]" => "startDate,endDate,manual",
          "limit" => "200"
        }
      )
      today = Date.today
      active_price = prices.any? do |price|
        attributes = price.fetch("attributes", {})
        active_on?(today, start_date: attributes["startDate"], end_date: attributes["endDate"])
      end
      errors << "#{product_id} has no price active on #{today.iso8601}" unless active_price
    rescue KeyError, ArgumentError => error
      errors << "#{product_id} has an invalid price schedule: #{error.message}"
    rescue TransportError => error
      errors << "#{product_id} price schedule could not be read: #{error.message}"
    end

    def validate_in_app_purchase_availability(product, product_id, required_territories, errors)
      availability = @client.get(
        "/v2/inAppPurchases/#{product.fetch('id')}/inAppPurchaseAvailability",
        query: { "fields[inAppPurchaseAvailabilities]" => "availableTerritories" }
      )
      territories = @client.collection(
        "/v1/inAppPurchaseAvailabilities/#{availability.fetch('data').fetch('id')}/availableTerritories",
        query: { "limit" => "200" }
      ).map { |territory| territory.fetch("id") }
      missing = required_territories - territories
      errors << "#{product_id} is unavailable in required territories: #{missing.join(', ')}" unless missing.empty?
    rescue KeyError => error
      errors << "#{product_id} has invalid availability metadata: #{error.message}"
    rescue TransportError => error
      errors << "#{product_id} availability could not be read: #{error.message}"
    end

    def validate_in_app_purchase_review_screenshot(product, product_id, errors)
      response = @client.get(
        "/v2/inAppPurchases/#{product.fetch('id')}",
        query: {
          "include" => "appStoreReviewScreenshot",
          "fields[inAppPurchaseAppStoreReviewScreenshots]" => "fileName,assetDeliveryState"
        }
      )
      screenshot = response.dig("data", "relationships", "appStoreReviewScreenshot", "data")
      unless screenshot
        errors << "#{product_id} has no App Review screenshot"
        return
      end

      screenshot_resource = response.fetch("included", []).find do |item|
        item["type"] == "inAppPurchaseAppStoreReviewScreenshots" && item["id"] == screenshot["id"]
      end
      unless screenshot_resource
        errors << "#{product_id} review screenshot metadata is missing"
        return
      end

      screenshot_attributes = screenshot_resource.fetch("attributes", {})
      delivery_state = screenshot_attributes.dig("assetDeliveryState", "state")
      errors << "#{product_id} review screenshot has delivery state #{delivery_state.inspect}" unless
        delivery_state == "COMPLETE"
      errors << "#{product_id} review screenshot has no file name" if
        screenshot_attributes["fileName"].to_s.strip.empty?
    end

    def active_on?(date, start_date:, end_date:)
      starts_on = start_date.nil? ? nil : Date.iso8601(start_date)
      ends_on = end_date.nil? ? nil : Date.iso8601(end_date)
      (starts_on.nil? || starts_on <= date) && (ends_on.nil? || ends_on >= date)
    end

    def normalized_text(value)
      value.to_s.split.join(" ")
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def find_build(platform:, version:, build_number:)
      raise Error, "Unsupported platform #{platform}" unless PLATFORMS.include?(platform)

      builds = @client.collection(
        "/v1/builds",
        query: AppStoreConnect.build_filters(
          app_id: @app_id,
          version: version,
          build_number: build_number,
          platform: platform
        )
      )
      raise Error, "Apple returned more than one #{platform} build for #{version} (#{build_number})" if builds.length > 1

      builds.first
    end

    def highest_build_number(platform:, version: nil)
      raise Error, "Unsupported platform #{platform}" unless PLATFORMS.include?(platform)

      builds = @client.collection(
        "/v1/builds",
        query: AppStoreConnect.build_history_filters(
          app_id: @app_id,
          platform: platform,
          version: version
        )
      )
      builds.map { |build| normalized_build_number(build.dig("attributes", "version")) }
        .max { |left, right| compare_build_numbers(left, right) }
    end

    def normalized_build_number(value)
      text = value.to_s
      unless /\A(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){0,2}\z/.match?(text)
        raise Error, "Unsupported Apple build number #{text.inspect}"
      end

      text
    end

    def compare_build_numbers(left, right)
      left_components = left.split(".").map(&:to_i).fill(0, left.count(".") + 1...3)
      right_components = right.split(".").map(&:to_i).fill(0, right.count(".") + 1...3)
      left_components <=> right_components
    end

    def require_valid_builds(version:, build_number:)
      PLATFORMS.to_h do |platform|
        build = find_build(platform: platform, version: version, build_number: build_number)
        raise Error, "Missing #{platform} build #{version} (#{build_number})" unless build

        state = build.dig("attributes", "processingState")
        raise Error, "#{platform} build is #{state}, not VALID" unless state == "VALID"

        validate_export_compliance(build)
        [platform, build]
      end
    end

    def validate_export_compliance(build)
      value = build.dig("attributes", "usesNonExemptEncryption")
      return if value == false

      raise Error.new(
        "Build #{build.fetch("id")} does not declare exempt encryption",
        remediation: "Set ITSAppUsesNonExemptEncryption in Info.plist or answer the export compliance " \
          "question for the build in App Store Connect."
      )
    end

    def beta_groups
      @client.collection("/v1/apps/#{@app_id}/betaGroups", query: { "limit" => "200" })
    end

    def find_or_create_group(name:, internal:)
      candidates = beta_groups.select { |group| group.dig("attributes", "isInternalGroup") == internal }
      if name && !name.strip.empty?
        match = candidates.find { |group| group.dig("attributes", "name") == name }
        return match if match

        response = @client.post(
          "/v1/betaGroups",
          body: AppStoreConnect.beta_group_payload(app_id: @app_id, name: name, internal: internal)
        )
        return response.fetch("data")
      end

      return candidates.first if candidates.length == 1

      names = candidates.map { |group| group.dig("attributes", "name") }.compact
      raise Error, "Specify a beta group. Available groups: #{names.empty? ? "none" : names.join(", ")}"
    end

    def add_builds_to_group(group_id, build_ids)
      existing_ids = @client.collection(
        "/v1/betaGroups/#{group_id}/builds",
        query: { "limit" => "200" }
      ).map { |build| build.fetch("id") }
      missing = build_ids - existing_ids
      return if missing.empty?

      @client.post(
        "/v1/betaGroups/#{group_id}/relationships/builds",
        body: AppStoreConnect.beta_group_builds_payload(missing)
      )
    end

    def disable_mobile_builds_on_other_platforms(group)
      attributes = group.fetch("attributes", {})
      return if attributes["iosBuildsAvailableForAppleSiliconMac"] == false &&
                attributes["iosBuildsAvailableForAppleVision"] == false

      @client.patch(
        "/v1/betaGroups/#{group.fetch("id")}",
        body: {
          data: {
            type: "betaGroups",
            id: group.fetch("id"),
            attributes: {
              iosBuildsAvailableForAppleSiliconMac: false,
              iosBuildsAvailableForAppleVision: false
            }
          }
        }
      )
    end

    def validate_beta_app_localizations
      localizations = @client.collection(
        "/v1/apps/#{@app_id}/betaAppLocalizations",
        query: { "limit" => "50" }
      )
      missing = localizations.filter_map do |localization|
        locale = localization.dig("attributes", "locale")
        description = localization.dig("attributes", "description").to_s.strip
        locale if description.empty?
      end
      if localizations.empty? || !missing.empty?
        labels = localizations.empty? ? "all locales" : missing.join(", ")
        raise Error, "TestFlight app descriptions are missing for #{labels}"
      end
    end

    def validate_beta_review_details
      details = @client.collection(
        "/v1/betaAppReviewDetails",
        query: {
          "filter[app]" => @app_id,
          "fields[betaAppReviewDetails]" =>
            "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName," \
            "demoAccountPassword,demoAccountRequired,notes",
          "limit" => "10"
        }
      )
      raise Error, "TestFlight beta review contact information is missing" if details.empty?
      raise Error, "Apple returned multiple beta review detail records" if details.length > 1

      validate_review_contact_and_demo_account(
        details.first.fetch("attributes", {}),
        context: "TestFlight beta review"
      )
    end

    def validate_app_store_review_details(versions)
      versions.each do |platform, app_store_version|
        response = @client.get(
          "/v1/appStoreVersions/#{app_store_version.fetch('id')}/appStoreReviewDetail",
          query: {
            "fields[appStoreReviewDetails]" =>
              "contactFirstName,contactLastName,contactPhone,contactEmail,demoAccountName," \
              "demoAccountPassword,demoAccountRequired,notes"
          }
        )
        attributes = response.dig("data", "attributes")
        raise Error, "#{platform} App Store review details are missing" unless attributes

        validate_review_contact_and_demo_account(attributes, context: "#{platform} App Store review")
      end
    end

    def validate_review_contact_and_demo_account(attributes, context:)
      required = %w[contactFirstName contactLastName contactPhone contactEmail]
      missing = required.select { |name| attributes[name].to_s.strip.empty? }
      unless missing.empty?
        raise Error, "#{context} fields are missing: #{missing.join(', ')}"
      end
      phone = attributes.fetch("contactPhone").strip
      unless phone.match?(/\A\+[1-9][0-9]{7,14}\z/)
        raise Error, "#{context} contact phone must use international E.164 format"
      end
      raise Error, "#{context} must require a demo account" unless attributes["demoAccountRequired"] == true

      account_fields = %w[demoAccountName demoAccountPassword]
      missing_account_fields = account_fields.select { |name| attributes[name].to_s.strip.empty? }
      unless missing_account_fields.empty?
        raise Error, "#{context} demo account fields are missing: #{missing_account_fields.join(', ')}"
      end
      raise Error, "#{context} notes are missing" if attributes["notes"].to_s.strip.empty?
    end

    def upsert_build_localizations(build_id, localization_paths)
      existing = @client.collection(
        "/v1/builds/#{build_id}/betaBuildLocalizations",
        query: { "limit" => "50" }
      ).to_h { |item| [item.dig("attributes", "locale"), item] }

      localization_paths.each do |locale, path|
        text = File.read(path, encoding: "UTF-8").strip
        raise Error, "TestFlight text is empty for #{locale}" if text.empty?

        item = existing[locale]
        if item
          @client.patch(
            "/v1/betaBuildLocalizations/#{item.fetch("id")}",
            body: {
              data: {
                type: "betaBuildLocalizations",
                id: item.fetch("id"),
                attributes: { whatsNew: text }
              }
            }
          )
        else
          @client.post(
            "/v1/betaBuildLocalizations",
            body: {
              data: {
                type: "betaBuildLocalizations",
                attributes: { locale: locale, whatsNew: text },
                relationships: { build: { data: { type: "builds", id: build_id } } }
              }
            }
          )
        end
      end
    end

    # Read-only cross-platform preflight. The per-platform sync loop can only
    # reject un-cancelable release-note changes after earlier platforms already
    # canceled their App Review; checking every platform first makes a
    # mixed-state release fail without any side effect. The sync loop stays
    # authoritative for what actually gets written.
    def preflight_release_note_changes!(versions, localization_paths, submit:)
      versions.each do |platform, app_store_version|
        paths = localization_paths.fetch(platform, {})
        next if paths.empty?

        state = version_state(app_store_version)
        next unless SUBMITTED_VERSION_STATES.include?(state)
        next if PRE_ACCEPTANCE_VERSION_STATES.include?(state)
        next if app_store_release_notes_match?(app_store_version.fetch("id"), paths)
        next unless submit

        raise Error,
              "#{platform} App Store version #{app_store_version.dig('attributes', 'versionString')} is in #{state} with different release notes; " \
              "Apple cannot cancel App Review from that state"
      end
    end

    # Cross-platform preflight for planned release-note changes. Invoked inside
    # resolve_app_store_versions_for_submission AFTER materialization but BEFORE
    # any cancellation or replacement mutation (see PROJECT-TRAPS:
    # stable-release-review-notes-preflight). Two-phase procedure guarantees
    # equivalence with the old single-pass behavior while adding coverage for
    # finding 2 (non-pre-acceptance differing-notes) and finding 3 (missing sibling
    # submission when one platform is cancelable).
    def preflight_planned_release_note_changes!(plans, localization_paths)
      # Phase 1: hard-block all non-pre-acceptance platforms with differing notes.
      # This preserves the existing error ordering for mixed-state scenarios.
      plans.each do |platform, plan|
        next unless plan[:target]

        state = version_state(plan.fetch(:target))
        next unless SUBMITTED_VERSION_STATES.include?(state)

        paths = localization_paths.fetch(platform, {})
        next if paths.empty? || app_store_release_notes_match?(plan.fetch(:target).fetch("id"), paths)

        unless PRE_ACCEPTANCE_VERSION_STATES.include?(state)
          raise Error,
                "#{platform} App Store version #{plan.fetch(:target).dig('attributes', 'versionString')} is in #{state} with different release notes; " \
                "Apple cannot cancel App Review from that state"
        end
      end

      # Phase 2: read-only feasibility probes for PRE_ACCEPTANCE targets with
      # differing notes. The probe result is discarded; we only care that it
      # would not raise a missing-submission or ambiguous-review error.
      plans.each do |platform, plan|
        next unless plan[:target]

        state = version_state(plan.fetch(:target))
        next unless PRE_ACCEPTANCE_VERSION_STATES.include?(state)

        paths = localization_paths.fetch(platform, {})
        next if paths.empty? || app_store_release_notes_match?(plan.fetch(:target).fetch("id"), paths)

        # Pre-mutation feasibility check (finding 3): would this target's
        # cancellation be blocked by a missing review submission?
        cancellation_plans(platform: platform, candidates: [plan.fetch(:target)])
      end
    end

    # Synchronizes App Store release notes for one platform. Apple locks whatsNew
    # once a version enters a submitted state: editable versions get their notes
    # written, submitted versions only get new notes when a requested submission
    # cancels the running App Review first. Returns the refreshed app version
    # when its state changed mid-run, nil when nothing changed.
    def synchronize_app_store_release_notes(platform:, app_store_version:, version:, localization_paths:, submit:)
      return nil if localization_paths.empty?

      current = app_store_version
      changed = false
      cancellations = 0
      loop do
        state = version_state(current)
        unless SUBMITTED_VERSION_STATES.include?(state)
          refreshed = upsert_app_store_localizations(current.fetch("id"), localization_paths)
          return changed ? current : nil if refreshed.nil?

          current = refreshed
          changed = true
          next
        end

        if app_store_release_notes_match?(current.fetch("id"), localization_paths)
          append_summary(
            "Skipped #{platform} whatsNew update (version #{version} in #{state}); release notes already match."
          )
          return changed ? current : nil
        end
        unless submit
          append_summary(
            "Skipped #{platform} whatsNew update (version #{version} in #{state}). " \
            "App Review was not canceled because submission was not requested."
          )
          return changed ? current : nil
        end
        unless PRE_ACCEPTANCE_VERSION_STATES.include?(state)
          raise Error,
                "#{platform} App Store version #{version} is in #{state} with different release notes; " \
                "Apple cannot cancel App Review from that state"
        end
        if cancellations >= RELEASE_NOTE_RESUBMIT_LIMIT
          raise Error,
                "#{platform} App Store version #{version} kept locking release notes after " \
                "#{cancellations} review cancellations"
        end

        plan = cancellation_plans(platform: platform, candidates: [current]).fetch(0)
        cancel_superseded_app_version(plan, target_version: version)
        current = read_app_store_version(current.fetch("id"))
        changed = true
        cancellations += 1
      end
    end

    def app_store_release_notes_match?(version_id, localization_paths)
      existing = read_app_store_localization_notes(version_id)
      localization_paths.all? do |locale, path|
        item = existing[locale]
        # Compare whitespace-insensitively: editors that touch App Store Connect
        # notes manually can introduce line-ending or spacing drift that must not
        # trigger a needless review cancellation.
        item && normalized_text(item.dig("attributes", "whatsNew")) == normalized_text(File.read(path, encoding: "UTF-8"))
      end
    end

    def read_app_store_localization_notes(version_id)
      @client.collection(
        "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations",
        query: {
          "fields[appStoreVersionLocalizations]" => "locale,whatsNew",
          "limit" => "50"
        }
      ).to_h { |item| [item.dig("attributes", "locale"), item] }
    end

    def upsert_app_store_localizations(
      version_id,
      localization_paths,
      timeout_seconds: WHATS_NEW_LOCK_TIMEOUT_SECONDS,
      poll_seconds: WHATS_NEW_LOCK_POLL_SECONDS
    )
      return nil if localization_paths.empty?

      existing = read_app_store_localization_notes(version_id)

      localization_paths.each do |locale, path|
        text = File.read(path, encoding: "UTF-8").strip
        raise Error, "App Store release notes are empty for #{locale}" if text.empty?

        item = existing[locale]
        next if item && item.dig("attributes", "whatsNew") == text

        refreshed = write_app_store_localization(
          version_id,
          item,
          locale,
          text,
          timeout_seconds: timeout_seconds,
          poll_seconds: poll_seconds
        )
        return refreshed if refreshed
      end
      nil
    end

    # Writes one whatsNew locale. Returns the refreshed app version when Apple
    # moved the version into a submitted state mid-flight (the caller must stop
    # editing); returns nil after a successful write.
    def write_app_store_localization(
      version_id,
      item,
      locale,
      text,
      timeout_seconds: WHATS_NEW_LOCK_TIMEOUT_SECONDS,
      poll_seconds: WHATS_NEW_LOCK_POLL_SECONDS
    )
      deadline = @monotonic_clock.call + timeout_seconds
      begin
        if item
          @client.patch(
            "/v1/appStoreVersionLocalizations/#{item.fetch('id')}",
            body: AppStoreConnect.app_store_localization_update_payload(
              localization_id: item.fetch("id"),
              whats_new: text
            )
          )
        else
          @client.post(
            "/v1/appStoreVersionLocalizations",
            body: AppStoreConnect.app_store_localization_payload(
              version_id: version_id,
              locale: locale,
              whats_new: text
            )
          )
        end
        nil
      rescue APIError => error
        # Apple can transition a version to a submitted state, or keep notes briefly
        # locked while a review cancellation settles, between our state read and
        # the write.
        raise unless error.status == 409 && whats_new_locked?(error)

        current = read_app_store_version(version_id)
        state = version_state(current)
        if SUBMITTED_VERSION_STATES.include?(state)
          append_summary(
            "Skipped whatsNew update for #{locale} (App Store version moved to #{state} on Apple's side)."
          )
          return current
        end

        if @monotonic_clock.call >= deadline
          raise Error,
                "App Store version stayed locked in #{state} for #{timeout_seconds}s: #{error.message}"
        end
        @sleeper.call(poll_seconds)
        retry
      end
    end

    def whats_new_locked?(error)
      error.codes.include?("STATE_ERROR") && error.message.include?("whatsNew")
    end

    def submit_beta_review(build)
      response = @client.get(
        "/v1/builds/#{build.fetch("id")}",
        query: { "include" => "betaAppReviewSubmission" }
      )
      relationship = response.dig("data", "relationships", "betaAppReviewSubmission", "data")
      submission = response.fetch("included", []).find do |item|
        relationship && item["type"] == "betaAppReviewSubmissions" && item["id"] == relationship["id"]
      end
      state = submission&.dig("attributes", "betaReviewState")
      return if REVIEWED_BUILD_STATES.include?(state)
      raise Error, "Build #{build.fetch("id")} was rejected by TestFlight review" if state == "REJECTED"

      begin
        @client.post(
          "/v1/betaAppReviewSubmissions",
          body: AppStoreConnect.beta_review_payload(build.fetch("id"))
        )
      rescue APIError => error
        # A repeated distribution can post before Apple exposes the first submission.
        raise unless [409, 422].include?(error.status)

        puts "Apple reports an existing TestFlight review submission for build #{build.fetch('id')}: " \
             "#{error.message}"
        raise unless beta_review_state(build) && beta_review_state(build) != "REJECTED"
      end
    end

    def beta_review_state(build)
      response = @client.get(
        "/v1/builds/#{build.fetch("id")}",
        query: { "include" => "betaAppReviewSubmission" }
      )
      response.fetch("included", []).find { |item| item["type"] == "betaAppReviewSubmissions" }
              &.dig("attributes", "betaReviewState")
    end

    def resolve_app_store_versions_for_submission(
      version:,
      builds:,
      localization_paths:,
      create_versions:,
      automatic_release:
    )
      target_components = app_version_components(version)
      plans = PLATFORMS.to_h do |platform|
        [platform, app_store_version_plan(
          platform: platform,
          target_version: version,
          target_components: target_components,
          create_versions: create_versions
        )]
      end

      validate_localization_paths(localization_paths)
      # Validate the state of every existing target on both platforms before the first mutation.
      # Creating a missing version is idempotent, but it must not precede a predictable failure
      # on the other platform.
      preflight_existing_target_states!(plans)
      materialize_missing_app_store_versions(plans, version: version)
      preflight_planned_release_note_changes!(plans, localization_paths)
      preflight_app_store_version_plans(
        plans,
        builds: builds,
        automatic_release: automatic_release
      )

      # Apple has no atomic cross-platform replacement operation. Validate both plans before canceling either one.
      plans.each_value do |plan|
        plan.fetch(:cancellations).each do |cancellation|
          cancel_superseded_app_version(cancellation, target_version: version)
        end
      end

      plans.to_h do |platform, plan|
        app_store_version = if plan[:target]
                              read_app_store_version(plan.fetch(:target).fetch("id"))
                            elsif plan[:replacement]
                              rename_rejected_app_store_version(
                                plan.fetch(:replacement),
                                platform: platform,
                                target_version: version
                              )
                            else
                              find_or_create_app_store_version(platform: platform, version: version)
                            end
        [platform, app_store_version]
      end
    end

    def app_store_version_plan(platform:, target_version:, target_components:, create_versions:)
      versions = @client.collection(
        "/v1/apps/#{@app_id}/appStoreVersions",
        query: {
          "filter[platform]" => platform,
          "fields[appStoreVersions]" => "platform,versionString,appVersionState,releaseType",
          "limit" => "200"
        }
      )
      targets = versions.select do |item|
        item.dig("attributes", "versionString") == target_version
      end
      if targets.length > 1
        raise Error, "Apple returned multiple #{platform} App Store versions for #{target_version}"
      end
      target = targets.first

      active_candidates = versions.select do |item|
        SUPERSEDED_VERSION_STATES.include?(version_state(item)) && item != target
      end
      active_candidates.each do |app_store_version|
        existing_version = app_store_version.dig("attributes", "versionString").to_s
        existing_components = app_version_components(existing_version)
        if (existing_components <=> target_components) >= 0
          raise Error,
                "#{platform} App Store version #{existing_version} cannot be superseded by #{target_version}"
        end
      end
      if active_candidates.length > 1
        versions_text = active_candidates.map { |item| item.dig("attributes", "versionString") }.join(", ")
        raise Error, "Apple returned multiple active #{platform} versions to supersede: #{versions_text}"
      end

      if target.nil? && !create_versions
        raise Error, "Missing #{platform} App Store version #{target_version}"
      end

      replacement = nil
      if target.nil?
        replacement = active_candidates.first
        unless replacement
          recoverable = versions.select do |item|
            next false unless EDITABLE_VERSION_STATES.include?(version_state(item))

            existing_version = item.dig("attributes", "versionString").to_s
            (app_version_components(existing_version) <=> target_components).negative?
          end
          if recoverable.length > 1
            versions_text = recoverable.map { |item| item.dig("attributes", "versionString") }.join(", ")
            raise Error, "Apple returned multiple editable #{platform} versions to rename: #{versions_text}"
          end
          replacement = recoverable.first
        end
      end

      {
        platform: platform,
        target: target,
        replacement: replacement,
        cancellations: cancellation_plans(platform: platform, candidates: active_candidates)
      }
    end

    def preflight_existing_target_states!(plans)
      invalid = plans.to_a.filter_map do |platform, plan|
        target = plan[:target]
        next unless target

        state = version_state(target)
        next if SUBMITTED_VERSION_STATES.include?(state) || EDITABLE_VERSION_STATES.include?(state)

        "#{platform}=#{state}"
      end
      return if invalid.empty?

      raise Error.new(
        "App versions cannot use this release workflow from states: #{invalid.join(', ')}",
        category: :release_state,
        remediation: unusable_version_state_remediation
      )
    end

    def unusable_version_state_remediation
      "The named version is no longer editable (for example REPLACED_WITH_NEW_VERSION or " \
        "DEVELOPER_REMOVED_FROM_SALE). Publish the GitHub release with a higher version number. " \
        "No Apple state was changed."
    end

    def materialize_missing_app_store_versions(plans, version:)
      plans.each do |platform, plan|
        next if plan[:target] || plan[:replacement]

        plan[:target] = find_or_create_app_store_version(platform: platform, version: version)
        append_summary("Prepared #{platform} App Store version #{version}.")
      end
    end

    def cancellation_plans(platform:, candidates:)
      return [] if candidates.empty?

      submissions = review_submissions(
        platform: platform,
        states: CANCELABLE_REVIEW_SUBMISSION_STATES + TRANSITIONAL_REVIEW_SUBMISSION_STATES
      )
      candidates.map do |app_store_version|
        existing_version = app_store_version.dig("attributes", "versionString").to_s
        matching = submissions.select do |submission|
          review_submission_version_id(submission) == app_store_version.fetch("id")
        end
        # Apple retains completed review attempts for a version that was submitted again.
        # Prefer its active attempt. Without one, the most recently submitted attempt produced the
        # version's current review result: an approved version cannot be submitted again.
        active = matching.reject { |submission| submission.dig("attributes", "state") == "COMPLETE" }
        matching = active.empty? ? latest_completed_review_submission(matching) : active
        if matching.empty?
          raise Error,
                "Missing #{platform} review submission for App Store version #{existing_version}"
        end
        if matching.length > 1
          raise Error,
                "Apple returned multiple #{platform} review submissions for App Store version #{existing_version}: " \
                "#{submission_list(matching)}"
        end

        submission = matching.fetch(0)
        submission_state = submission.dig("attributes", "state")
        allowed_states = CANCELABLE_REVIEW_SUBMISSION_STATES + TRANSITIONAL_REVIEW_SUBMISSION_STATES
        unless allowed_states.include?(submission_state)
          raise Error,
                "#{platform} review submission for #{existing_version} cannot be canceled from #{submission_state}"
        end

        {
          platform: platform,
          version: app_store_version,
          version_string: existing_version,
          submission: submission
        }
      end
    end

    def validate_localization_paths(localization_paths)
      localization_paths.each do |platform, paths|
        paths.each do |locale, path|
          text = File.read(path, encoding: "UTF-8").strip
          raise Error, "#{platform} App Store release notes are empty for #{locale}" if text.empty?
        rescue Errno::ENOENT
          raise Error, "#{platform} App Store release notes are missing for #{locale}: #{path}"
        end
      end
    end

    def preflight_app_store_version_plans(plans, builds:, automatic_release:)
      review_sources = {}
      plans.each do |platform, plan|
        target = plan[:target]
        source = target || plan[:replacement]
        review_sources[platform] = source if source
        next unless target

        state = version_state(target)
        unless SUBMITTED_VERSION_STATES.include?(state) || EDITABLE_VERSION_STATES.include?(state)
          raise Error, "#{platform} App Store version cannot use this release workflow from #{state}"
        end
        next unless SUBMITTED_VERSION_STATES.include?(state)

        release_type = target.dig("attributes", "releaseType")
        if automatic_release && release_type != "AFTER_APPROVAL"
          raise Error, "#{platform} is already submitted with release type #{release_type || 'UNKNOWN'}"
        end
        require_attached_build(target.fetch("id"), builds.fetch(platform).fetch("id"))
      end

      validate_app_store_review_details(review_sources) unless review_sources.empty?
    end

    def rename_rejected_app_store_version(app_store_version, platform:, target_version:)
      version_id = app_store_version.fetch("id")
      current = read_app_store_version(version_id)
      state = version_state(current)
      unless EDITABLE_VERSION_STATES.include?(state)
        raise Error,
              "#{platform} App Store version #{current.dig('attributes', 'versionString')} changed to #{state} " \
              "before it could be renamed to #{target_version}"
      end

      previous_version = current.dig("attributes", "versionString")
      updated = nil
      begin
        @client.patch(
          "/v1/appStoreVersions/#{version_id}",
          body: AppStoreConnect.app_store_version_number_payload(
            version_id: version_id,
            version: target_version
          )
        )
      rescue APIError => error
        raise unless [409, 422].include?(error.status)

        authoritative = read_app_store_version(version_id)
        if authoritative.dig("attributes", "versionString") == target_version
          updated = authoritative
        else
          authoritative_version = authoritative.dig("attributes", "versionString") || "UNKNOWN"
          authoritative_state = version_state(authoritative)
          raise Error,
                "#{platform} App Store version #{previous_version} could not be changed to #{target_version}; " \
                "Apple returned HTTP #{error.status}. Apple still reports version #{authoritative_version} in " \
                "#{authoritative_state}; the workflow did not delete or create a version."
        end
      end
      updated ||= read_app_store_version(version_id)
      unless updated.dig("attributes", "versionString") == target_version
        raise Error, "#{platform} App Store version did not change to #{target_version}"
      end

      append_summary("Changed #{platform} App Store version #{previous_version} to #{target_version}.")
      updated
    end

    def cancel_superseded_app_version(plan, target_version:, timeout_seconds: 900, poll_seconds: 10)
      submission_id = plan.fetch(:submission).fetch("id")
      version_id = plan.fetch(:version).fetch("id")
      deadline = @monotonic_clock.call + timeout_seconds
      cancel_requested = TRANSITIONAL_REVIEW_SUBMISSION_STATES.include?(
        plan.dig(:submission, "attributes", "state")
      )

      loop do
        app_store_version = read_app_store_version(version_id)
        state = version_state(app_store_version)
        if state == "DEVELOPER_REJECTED"
          append_summary(
            "Removed #{plan.fetch(:platform)} #{plan.fetch(:version_string)} from App Review before " \
            "submitting #{target_version}."
          )
          return
        end
        unless SUPERSEDED_VERSION_STATES.include?(state)
          raise Error,
                "#{plan.fetch(:platform)} App Store version #{plan.fetch(:version_string)} changed to #{state} " \
                "while it was being superseded"
        end

        submission = read_review_submission(submission_id)
        submission_state = submission.dig("attributes", "state")
        # A cancellation can reach COMPLETE before the app version reaches DEVELOPER_REJECTED.
        # On a fresh workflow process, the pre-acceptance app state distinguishes that race from
        # a completed review that still needs cancellation before release.
        if submission_state == "COMPLETE" && PRE_ACCEPTANCE_VERSION_STATES.include?(state)
          cancel_requested = true
        end
        if CANCELABLE_REVIEW_SUBMISSION_STATES.include?(submission_state) && !cancel_requested
          begin
            @client.patch(
              "/v1/reviewSubmissions/#{submission_id}",
              body: AppStoreConnect.cancel_review_payload(submission_id)
            )
            cancel_requested = true
          rescue APIError => error
            raise unless [404, 409, 422].include?(error.status)

            refreshed_version = read_app_store_version(version_id)
            if version_state(refreshed_version) == "DEVELOPER_REJECTED"
              cancel_requested = true
              next
            end

            refreshed_submission = read_review_submission(submission_id)
            refreshed_submission_state = refreshed_submission.dig("attributes", "state")
            if TRANSITIONAL_REVIEW_SUBMISSION_STATES.include?(refreshed_submission_state) ||
               refreshed_submission_state == "COMPLETE" && SUPERSEDED_VERSION_STATES.include?(
                 version_state(refreshed_version)
               )
              cancel_requested = true
            else
              raise error
            end
          end
        elsif !TRANSITIONAL_REVIEW_SUBMISSION_STATES.include?(submission_state) &&
              !(CANCELABLE_REVIEW_SUBMISSION_STATES.include?(submission_state) && cancel_requested)
          raise Error,
                "#{plan.fetch(:platform)} review submission for #{plan.fetch(:version_string)} changed to " \
                "#{submission_state} while cancellation was pending"
        end

        if @monotonic_clock.call >= deadline
          raise Error,
                "Timed out while canceling #{plan.fetch(:platform)} App Store version " \
                "#{plan.fetch(:version_string)} (version=#{state}, submission=#{submission_state})"
        end
        @sleeper.call(poll_seconds)
      end
    end

    def app_version_components(version)
      unless APP_VERSION_PATTERN.match?(version)
        raise Error, "App Store version #{version.inspect} must use MAJOR.MINOR.PATCH"
      end

      version.split(".").map { |component| Integer(component, 10) }
    end

    def review_submissions(platform:, states: nil)
      query = {
        "filter[platform]" => platform,
        "fields[reviewSubmissions]" => "platform,state,submittedDate,appStoreVersionForReview",
        "include" => "appStoreVersionForReview",
        "limit" => "200"
      }
      query["filter[state]"] = states.join(",") if states
      @client.collection("/v1/apps/#{@app_id}/reviewSubmissions", query: query)
    end

    # Returns the uniquely newest completed submission. Missing or equal submission dates stay ambiguous,
    # so the caller refuses to cancel instead of choosing an arbitrary attempt.
    def latest_completed_review_submission(submissions)
      return submissions if submissions.length < 2

      dated = submissions.map do |submission|
        date = submission.dig("attributes", "submittedDate")
        [submission, date && Time.iso8601(date)]
      rescue ArgumentError
        [submission, nil]
      end
      return submissions if dated.any? { |_submission, date| date.nil? }

      newest = dated.map(&:last).max
      latest = dated.select { |_submission, date| date == newest }.map(&:first)
      latest.length == 1 ? latest : submissions
    end

    def review_submission_version_id(submission)
      version_id = submission.dig("relationships", "appStoreVersionForReview", "data", "id")
      return version_id if version_id

      response = @client.get(
        "/v1/reviewSubmissions/#{submission.fetch('id')}",
        query: {
          "fields[reviewSubmissions]" => "platform,state,appStoreVersionForReview",
          "include" => "appStoreVersionForReview"
        }
      )
      response.dig("data", "relationships", "appStoreVersionForReview", "data", "id") ||
        raise(Error, "Review submission #{submission.fetch('id')} has no App Store version")
    end

    def read_app_store_version(version_id)
      @client.get(
        "/v1/appStoreVersions/#{version_id}",
        query: { "fields[appStoreVersions]" => "platform,versionString,appVersionState,releaseType" }
      ).fetch("data")
    end

    def read_review_submission(submission_id)
      @client.get(
        "/v1/reviewSubmissions/#{submission_id}",
        query: { "fields[reviewSubmissions]" => "platform,state" }
      ).fetch("data")
    end

    def find_app_store_version(platform:, version:)
      versions = @client.collection(
        "/v1/apps/#{@app_id}/appStoreVersions",
        query: {
          "filter[platform]" => platform,
          "filter[versionString]" => version,
          "limit" => "10"
        }
      )
      raise Error, "Apple returned multiple #{platform} App Store versions for #{version}" if versions.length > 1

      versions.first
    end

    def require_app_store_version(platform:, version:)
      find_app_store_version(platform: platform, version: version) ||
        raise(Error, "Missing #{platform} App Store version #{version}")
    end

    def find_or_create_app_store_version(platform:, version:)
      existing = find_app_store_version(platform: platform, version: version)
      return existing if existing

      response = @client.post(
        "/v1/appStoreVersions",
        body: AppStoreConnect.app_store_version_payload(
          app_id: @app_id,
          platform: platform,
          version: version
        )
      )
      response.fetch("data")
    end

    def ensure_automatic_release(app_store_version, platform:, state:)
      release_type = app_store_version.dig("attributes", "releaseType")
      return if release_type == "AFTER_APPROVAL"
      if SUBMITTED_VERSION_STATES.include?(state)
        raise Error, "#{platform} is already submitted with release type #{release_type || 'UNKNOWN'}"
      end

      @client.patch(
        "/v1/appStoreVersions/#{app_store_version.fetch('id')}",
        body: AppStoreConnect.automatic_release_payload(app_store_version.fetch("id"))
      )
      app_store_version["attributes"]["releaseType"] = "AFTER_APPROVAL"
    end

    def find_or_create_review_submission(platform:, version_id: nil, timeout_seconds: 900, poll_seconds: 10)
      deadline = @monotonic_clock.call + timeout_seconds
      cancel_requested = {}
      loop do
        open = review_submissions(platform: platform, states: OPEN_REVIEW_SUBMISSION_STATES).select do |item|
          OPEN_REVIEW_SUBMISSION_STATES.include?(item.dig("attributes", "state"))
        end
        ready = open.select { |item| item.dig("attributes", "state") == "READY_FOR_REVIEW" }
        if ready.length > 1
          raise Error.new(
            "Apple returned multiple open #{platform} review submissions: #{submission_list(ready)}",
            category: :apple_state_conflict,
            remediation: "Open App Store Connect > App Review, remove all but one draft submission for " \
                         "#{platform}, then re-run the failed jobs."
          )
        end
        blocking = open - ready
        return ready.first if ready.one? && blocking.empty?

        if blocking.empty?
          response = @client.post(
            "/v1/reviewSubmissions",
            body: AppStoreConnect.review_submission_payload(app_id: @app_id, platform: platform)
          )
          return response.fetch("data")
        end

        blocking.each do |submission|
          settle_blocking_review_submission(
            submission,
            platform: platform,
            version_id: version_id,
            cancel_requested: cancel_requested
          )
        end

        if @monotonic_clock.call >= deadline
          raise Error.new(
            "Timed out while #{platform} review submissions settled: #{submission_list(blocking)}",
            category: :apple_state_conflict,
            remediation: "Apple is still processing the cancellation. Wait some minutes, check App Store " \
                         "Connect > App Review, then re-run the failed jobs."
          )
        end
        @sleeper.call(poll_seconds)
      end
    end

    # A rejected attempt stays open in UNRESOLVED_ISSUES and blocks the next submission of the
    # same platform. Apple does not accept new items in that state. The workflow cancels only
    # a rejected attempt of the version that it submits now. Every other open submission belongs
    # to a different owner decision and stops the run with an exact instruction.
    def settle_blocking_review_submission(submission, platform:, version_id:, cancel_requested:)
      submission_id = submission.fetch("id")
      state = submission.dig("attributes", "state")
      return if TRANSITIONAL_REVIEW_SUBMISSION_STATES.include?(state)
      return if cancel_requested[submission_id]

      same_version = version_id && review_submission_version_id_or_nil(submission) == version_id
      unless state == "UNRESOLVED_ISSUES" && same_version
        raise Error.new(
          "#{platform} review submission #{submission_id} is open in #{state} and blocks a new submission",
          category: :apple_state_conflict,
          remediation: "Open App Store Connect > App Review > submission #{submission_id}. Cancel it or " \
                       "finish it, then re-run the failed jobs. The workflow cancels only a rejected " \
                       "attempt of the version that it submits."
        )
      end

      begin
        @client.patch(
          "/v1/reviewSubmissions/#{submission_id}",
          body: AppStoreConnect.cancel_review_payload(submission_id)
        )
        append_summary("Canceled the rejected #{platform} review submission #{submission_id} before resubmission.")
      rescue APIError => error
        raise unless [409, 422].include?(error.status)

        refreshed = read_review_submission(submission_id).dig("attributes", "state")
        unless TRANSITIONAL_REVIEW_SUBMISSION_STATES.include?(refreshed) || refreshed == "COMPLETE"
          raise Error.new(
            "Apple refused to cancel the rejected #{platform} review submission #{submission_id} " \
            "(#{refreshed}): #{error.message}",
            category: :apple_state_conflict,
            remediation: "Open App Store Connect > App Review > submission #{submission_id}, resolve the " \
                         "rejected items or choose Resubmit to App Review there. Then re-run the failed " \
                         "jobs; an already submitted version is accepted."
          )
        end
      end
      cancel_requested[submission_id] = true
    end

    def review_submission_version_id_or_nil(submission)
      review_submission_version_id(submission)
    rescue Error
      nil
    end

    def submission_list(submissions)
      submissions.map { |item| "#{item.fetch('id')} (#{item.dig('attributes', 'state')})" }.join(", ")
    end

    def add_version_to_review_submission(submission_id:, version_id:)
      items = @client.collection(
        "/v1/reviewSubmissions/#{submission_id}/items",
        query: { "limit" => "200", "include" => "appStoreVersion" }
      )
      exists = items.any? do |item|
        item.dig("relationships", "appStoreVersion", "data", "id") == version_id
      end
      return if exists

      other_version_ids = items.filter_map do |item|
        item.dig("relationships", "appStoreVersion", "data", "id")
      end.uniq
      unless other_version_ids.empty?
        raise Error.new(
          "Open review submission #{submission_id} already contains another app version " \
          "(appStoreVersion ids: #{other_version_ids.join(', ')})",
          category: :apple_state_conflict,
          remediation: "Open App Store Connect > App Review > draft submission #{submission_id} and remove " \
                       "the other app version, or delete the draft. Then re-run the failed jobs."
        )
      end

      @client.post(
        "/v1/reviewSubmissionItems",
        body: AppStoreConnect.review_item_payload(
          submission_id: submission_id,
          version_id: version_id
        )
      )
    end

    def attach_build(version_id, build_id)
      @client.patch(
        "/v1/appStoreVersions/#{version_id}/relationships/build",
        body: AppStoreConnect.app_store_build_payload(build_id)
      )
    end

    def require_attached_build(version_id, expected_build_id)
      response = @client.get("/v1/appStoreVersions/#{version_id}/relationships/build")
      actual_build_id = response.dig("data", "id")
      return if actual_build_id == expected_build_id

      raise Error, "Submitted app version #{version_id} uses a different build"
    end

    def version_state(app_store_version)
      attributes = app_store_version.fetch("attributes")
      attributes["appVersionState"] || attributes["appStoreState"] || "UNKNOWN"
    end

    def write_output(name, value)
      return unless @output_path && !@output_path.empty?

      File.open(@output_path, "a") { |file| file.puts("#{name}=#{value}") }
    end

    def append_summary(message)
      puts message
      return unless @summary_path && !@summary_path.empty?

      File.open(@summary_path, "a") { |file| file.puts("- #{message}") }
    end
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      options = parse_options(argv)
      manager = manager_from_environment

      case command
      when "validate-sandbox-in-app-purchases"
        manager.validate_in_app_purchase_sandbox
      when "validate-in-app-purchases"
        manager.validate_in_app_purchases
      when "inspect-build"
        version = required_option(options, :version)
        build_number = required_option(options, :build_number)
        manager.inspect_build(
          platform: required_option(options, :platform),
          version: version,
          build_number: build_number
        )
      when "validate-build-number"
        manager.validate_build_number(
          version: required_option(options, :version),
          build_number: required_option(options, :build_number)
        )
      when "wait-builds"
        version = required_option(options, :version)
        build_number = required_option(options, :build_number)
        manager.wait_for_builds(
          version: version,
          build_number: build_number,
          timeout_seconds: options.fetch(:timeout, 2_700)
        )
      when "distribute-internal"
        version = required_option(options, :version)
        build_number = required_option(options, :build_number)
        manager.distribute_internal(
          version: version,
          build_number: build_number,
          group_name: options[:group],
          localization_paths: options[:localizations]
        )
      when "distribute-external"
        version = required_option(options, :version)
        build_number = required_option(options, :build_number)
        manager.distribute_external(
          version: version,
          build_number: build_number,
          group_name: required_option(options, :group),
          localization_paths: required_option(options, :localizations)
        )
      when "prepare-app-store"
        version = required_option(options, :version)
        build_number = required_option(options, :build_number)
        manager.prepare_app_store(
          version: version,
          build_number: build_number,
          submit: options.fetch(:submit, false),
          localization_paths: options[:localizations],
          create_versions: options.fetch(:create_versions, false),
          automatic_release: options.fetch(:automatic_release, false)
        )
      else
        raise Error, "Unknown command #{command.inspect}"
      end
    rescue Error, KeyError, ArgumentError => error
      report_failure(command, error)
      exit 1
    rescue StandardError => error
      report_failure(command, error, unexpected: true)
      exit 1
    end

    def self.report_failure(command, error, unexpected: false)
      report = if unexpected
                 {
                   category: :workflow_defect,
                   cause: (["#{error.class}: #{error.message}"] + error.backtrace.to_a.first(5)).join("\n"),
                   remediation: "This is a defect in .github/scripts/app_store_connect.rb. Open an issue with this log.",
                   rerun_safe: false
                 }
               else
                 AppStoreConnect.failure_report(error)
               end
      warn "Apple release action failed: #{error.message}"
      warn "Category: #{report.fetch(:category)}"
      warn "Remediation: #{report.fetch(:remediation)}"
      warn "Safe to re-run: #{report.fetch(:rerun_safe)}"

      annotation = "::error title=Apple release failed (#{report.fetch(:category)})::" \
        "#{escape_workflow_command(report.fetch(:cause))} Remediation: " \
        "#{escape_workflow_command(report.fetch(:remediation))}"
      puts annotation

      summary_path = ENV["GITHUB_STEP_SUMMARY"]
      return if summary_path.nil? || summary_path.empty?

      File.open(summary_path, "a") do |file|
        file.puts("## Apple release failed")
        file.puts
        file.puts("| Command | Category | Cause | Remediation | Safe to re-run |")
        file.puts("| --- | --- | --- | --- | --- |")
        file.puts(
          "| #{summary_value(command)} | #{summary_value(report.fetch(:category))} | " \
            "#{summary_value(report.fetch(:cause))} | #{summary_value(report.fetch(:remediation))} | " \
            "#{summary_value(report.fetch(:rerun_safe))} |"
        )
      end
    end

    def self.escape_workflow_command(value)
      value.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    end

    def self.summary_value(value)
      value.to_s.gsub("|", "\\|").gsub("\r", " ").gsub("\n", "<br>")
    end

    def self.parse_options(argv)
      options = { localizations: {} }
      OptionParser.new do |parser|
        parser.on("--platform PLATFORM") { |value| options[:platform] = value }
        parser.on("--version VERSION") { |value| options[:version] = value }
        parser.on("--build-number NUMBER") { |value| options[:build_number] = value }
        parser.on("--group NAME") { |value| options[:group] = value }
        parser.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
        parser.on("--submit") { options[:submit] = true }
        parser.on("--create-versions") { options[:create_versions] = true }
        parser.on("--automatic-release") { options[:automatic_release] = true }
        parser.on("--localization PLATFORM:LOCALE=PATH") do |value|
          key, path = value.split("=", 2)
          platform, locale = key.to_s.split(":", 2)
          unless PLATFORMS.include?(platform) && locale && !locale.empty? && path && !path.empty?
            raise OptionParser::InvalidArgument,
                  "#{value} (expected PLATFORM:LOCALE=PATH)"
          end

          options[:localizations][platform] ||= {}
          options[:localizations][platform][locale] = path
        end
      end.parse!(argv)
      options
    end

    def self.manager_from_environment
      private_key = Base64.strict_decode64(required_env("APP_STORE_CONNECT_PRIVATE_KEY_BASE64"))
      client = Client.new(
        issuer_id: required_env("APP_STORE_CONNECT_ISSUER_ID"),
        key_id: required_env("APP_STORE_CONNECT_KEY_ID"),
        private_key: private_key
      )
      ReleaseManager.new(client: client, app_id: required_env("APP_STORE_CONNECT_APP_ID"))
    rescue ArgumentError
      raise Error, "APP_STORE_CONNECT_PRIVATE_KEY_BASE64 is not valid Base64"
    end

    def self.required_env(name)
      value = ENV.fetch(name, "").strip
      raise Error, "Missing #{name}" if value.empty?

      value
    end

    def self.required_option(options, name)
      value = options[name]
      raise Error, "Missing --#{name.to_s.tr("_", "-")}" if value.nil? || value.respond_to?(:empty?) && value.empty?

      value
    end
  end
end

AppStoreConnect::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__

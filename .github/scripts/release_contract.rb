#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "base64"
require "json"
require_relative "release_identity"

module GitHubReleaseContract
  MAX_APPLE_RELEASE_NOTES_LENGTH = 4_000
  TAG_PATTERN = GitHubReleaseIdentity::TAG_PATTERN
  PLATFORMS = {
    "IOS" => "iOS and iPadOS",
    "MAC_OS" => "macOS"
  }.freeze
  PLATFORM_FILE_PREFIXES = {
    "IOS" => "ios",
    "MAC_OS" => "macos"
  }.freeze
  SHARED_PLATFORM_HEADING = "All Platforms"
  LOCALES = {
    "en-US" => "English",
    "de-DE" => "Deutsch"
  }.freeze

  class Error < StandardError; end

  Release = Data.define(:tag, :version, :prerelease, :channel, :notes)

  module_function

  def parse(payload)
    identity = GitHubReleaseIdentity.parse(payload)
    notes = extract_notes(payload.fetch("body", ""))
    Release.new(
      tag: identity.fetch("tag"),
      version: identity.fetch("version"),
      prerelease: identity.fetch("prerelease"),
      channel: identity.fetch("channel"),
      notes: notes
    )
  rescue GitHubReleaseIdentity::Error => error
    raise Error, error.message
  end

  def extract_notes(body)
    normalized_body = body.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    headings = normalized_body.scan(/^##[ \t]+(.+?)[ \t]*$/).flatten
    duplicates = headings.tally.select do |heading, count|
      LOCALES.value?(heading) && count > 1
    end.keys
    raise Error, "Release notes contain duplicate sections: #{duplicates.join(', ')}" unless duplicates.empty?

    locale_sections = LOCALES.to_h do |locale, heading|
      text = normalized_body[/^##[ \t]+#{Regexp.escape(heading)}[ \t]*$\n(?<text>.*?)(?=^##[ \t]+|\z)/m, :text]
      text = text.to_s.strip
      raise Error, "Release notes are missing the ## English section" if locale == "en-US" && text.empty?

      [locale, text.empty? ? nil : platform_notes(text, locale_heading: heading)]
    end

    PLATFORMS.to_h do |platform, platform_heading|
      english = locale_sections.fetch("en-US").fetch(platform)
      german = locale_sections.fetch("de-DE")&.fetch(platform) || english
      notes = { "en-US" => english, "de-DE" => german }
      notes.each do |locale, text|
        next if text.length <= MAX_APPLE_RELEASE_NOTES_LENGTH

        heading = LOCALES.fetch(locale)
        raise Error,
              "## #{heading} for #{platform_heading} exceeds #{MAX_APPLE_RELEASE_NOTES_LENGTH} characters"
      end
      [platform, notes]
    end
  end

  def platform_notes(text, locale_heading:)
    matches = text.to_enum(:scan, /^###[ \t]+(.+?)[ \t]*$/).map { Regexp.last_match.dup }
    return PLATFORMS.to_h { |platform, _heading| [platform, text] } if matches.empty?

    allowed = [SHARED_PLATFORM_HEADING, *PLATFORMS.values]
    headings = matches.map { |match| match[1] }
    unknown = headings.reject { |heading| allowed.include?(heading) }
    unless unknown.empty?
      raise Error, "## #{locale_heading} contains unsupported platform sections: #{unknown.uniq.join(', ')}"
    end

    duplicates = headings.tally.select { |_heading, count| count > 1 }.keys
    unless duplicates.empty?
      raise Error, "## #{locale_heading} contains duplicate platform sections: #{duplicates.join(', ')}"
    end

    preamble = text[0...matches.first.begin(0)].to_s.strip
    unless preamble.empty?
      raise Error, "## #{locale_heading} must put shared text under ### #{SHARED_PLATFORM_HEADING}"
    end

    sections = matches.each_with_index.to_h do |match, index|
      finish = matches[index + 1]&.begin(0) || text.length
      [match[1], text[match.end(0)...finish].to_s.strip]
    end
    shared = sections.fetch(SHARED_PLATFORM_HEADING, "")

    PLATFORMS.to_h do |platform, heading|
      combined = [shared, sections.fetch(heading, "")].reject(&:empty?).join("\n\n")
      if combined.empty?
        raise Error, "## #{locale_heading} has no release notes for #{heading}"
      end
      [platform, combined]
    end
  end

  def write(release, directory:, output_path: ENV["GITHUB_OUTPUT"], summary_path: ENV["GITHUB_STEP_SUMMARY"])
    FileUtils.mkdir_p(directory)
    release.notes.each do |platform, localizations|
      prefix = PLATFORM_FILE_PREFIXES.fetch(platform)
      localizations.each do |locale, text|
        File.write(File.join(directory, "#{prefix}.#{locale}.txt"), "#{text}\n", encoding: "UTF-8")
      end
    end

    if output_path && !output_path.empty?
      File.open(output_path, "a") do |output|
        output.puts("tag=#{release.tag}")
        output.puts("version=#{release.version}")
        output.puts("prerelease=#{release.prerelease}")
        output.puts("channel=#{release.channel}")
        output.puts("notes_ios_de_base64=#{Base64.strict_encode64(release.notes.dig('IOS', 'de-DE'))}")
        output.puts("notes_ios_en_base64=#{Base64.strict_encode64(release.notes.dig('IOS', 'en-US'))}")
        output.puts("notes_macos_de_base64=#{Base64.strict_encode64(release.notes.dig('MAC_OS', 'de-DE'))}")
        output.puts("notes_macos_en_base64=#{Base64.strict_encode64(release.notes.dig('MAC_OS', 'en-US'))}")
      end
    end

    return unless summary_path && !summary_path.empty?

    File.open(summary_path, "a") do |summary|
      summary.puts("## Apple release")
      summary.puts
      summary.puts("- Tag: #{release.tag}")
      summary.puts("- App version: #{release.version}")
      summary.puts("- Destination: #{release.prerelease ? 'internal TestFlight' : 'App Store review'}")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    payload_path, notes_directory = ARGV
    raise GitHubReleaseContract::Error, "Usage: release_contract.rb RELEASE_JSON NOTES_DIRECTORY" unless
      payload_path && notes_directory

    payload = JSON.parse(File.read(payload_path, encoding: "UTF-8"))
    release = GitHubReleaseContract.parse(payload)
    GitHubReleaseContract.write(release, directory: notes_directory)
  rescue GitHubReleaseContract::Error, JSON::ParserError, Errno::ENOENT => error
    warn "Invalid GitHub release: #{error.message}"
    exit 1
  end
end

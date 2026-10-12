#!/usr/bin/env ruby
# Local validation. No credentials or App Store Connect access.
locales = %w[en-US en-GB es-ES es-MX fr-FR it de-DE pt-BR ja uk]
limits = { "name" => 30, "subtitle" => 30, "promotional_text" => 170, "description" => 4000 }
root = File.expand_path("../fastlane/metadata", __dir__)
locales.each do |locale|
  limits.each do |field, limit|
    value = File.read(File.join(root, locale, "#{field}.txt")).strip
    abort "#{locale}/#{field} is empty or exceeds #{limit} characters" if value.empty? || value.length > limit
  end
  keywords = File.read(File.join(root, locale, "keywords.txt")).strip
  abort "#{locale}/keywords exceeds 100 UTF-8 bytes" if keywords.bytesize > 100
  abort "#{locale}/keywords still contains scuba" if keywords.split(",").any? { |word| word.downcase == "scuba" }
end
puts "Metadata limits pass for #{locales.length} locales."

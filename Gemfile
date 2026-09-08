source "https://rubygems.org"

gemspec

# Rails 7 calls JSON.generate(quirks_mode: true), which json 3 removed.
gem "json", "< 3"
gem "pg", "~> 1.5"
gem "puma", "~> 8.0"
gem "rackup", "~> 2.3"
gem "sinatra", "~> 4.2"
gem "sqlite3", "~> 2.0"

group :development, :test do
  gem "rspec", "~> 3.12"
  gem "rack-test", "~> 2.2"
end

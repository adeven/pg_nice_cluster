# -*- encoding: utf-8 -*-
require File.expand_path('../lib/pg_nice_cluster/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Paul H. Müller"]
  gem.email         = ["paul@adeven.com"]
  gem.description   = %q{a gem to enable the usage of postgres cluster command}
  gem.summary       = %q{this tool makes it possible to use the postgres cluster
                         command to clean up your database without write locking it}
  gem.homepage      = "http://www.adeven.com"
  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "pg_nice_cluster"
  gem.require_paths = ["lib"]
  gem.version       = PgNiceCluster::VERSION
  gem.add_dependency "pg"
  gem.add_dependency "trollop"
end

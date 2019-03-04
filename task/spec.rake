# frozen_string_literal: true

desc "Run specs"
task :spec do
  sh("bin/rspec")
end

namespace :spec do
  def safe_task(&block)
    yield
    true
  rescue StandardError
    false
  end

  desc "Ensure spec dependencies are installed"
  task :deps do
    deps = Hash[Gem::Specification.load("bundler.gemspec").development_dependencies.map do |d|
      [d.name, d.requirement.to_s]
    end]

    # JRuby can't build ronn, so we skip that
    deps.delete("ronn") if defined?(RUBY_ENGINE) && RUBY_ENGINE == "jruby"

    gem_install_command = "install --no-document --conservative " + deps.sort_by {|name, _| name }.map do |name, version|
      "'#{name}:#{version}'"
    end.join(" ")
    sh %(#{Gem.ruby} -S gem #{gem_install_command})
  end

  namespace :travis do
    task :deps do
      # Give the travis user a name so that git won't fatally error
      system "sudo sed -i 's/1000::/1000:Travis:/g' /etc/passwd"
      # Strip secure_path so that RVM paths transmit through sudo -E
      system "sudo sed -i '/secure_path/d' /etc/sudoers"
      # Install groff so ronn can generate man/help pages
      sh "sudo apt-get install groff-base -y"
      # Install graphviz so that the viz specs can run
      sh "sudo apt-get install graphviz -y 2>&1 | tail -n 2"

      # Install the gems with a consistent version of RubyGems
      sh "gem update --system 3.0.2"

      # Fix incorrect default gem specifications on ruby 2.6.1. Can be removed
      # when 2.6.2 is released and we start testing against it
      if RUBY_VERSION == "2.6.1"
        sh "gem install etc:1.0.1 --default"
        sh "gem install bundler:1.17.2 --default"
      end

      $LOAD_PATH.unshift("./spec")
      require "support/rubygems_ext"
      Spec::Rubygems::DEPS["codeclimate-test-reporter"] = "~> 0.6.0" if RUBY_VERSION >= "2.2.0"

      # Install the other gem deps, etc
      Rake::Task["spec:deps"].invoke
    end
  end

  task :clean do
    rm_rf "tmp"
  end

  desc "Run the real-world spec suite"
  task :realworld => %w[set_realworld spec]

  namespace :realworld do
    desc "Re-record cassettes for the realworld specs"
    task :record => %w[set_record realworld]

    task :set_record do
      ENV["BUNDLER_SPEC_FORCE_RECORD"] = "TRUE"
    end
  end

  task :set_realworld do
    ENV["BUNDLER_REALWORLD_TESTS"] = "1"
  end

  desc "Run the spec suite with the sudo tests"
  task :sudo => %w[set_sudo spec clean_sudo]

  task :set_sudo do
    ENV["BUNDLER_SUDO_TESTS"] = "1"
  end

  task :clean_sudo do
    puts "Cleaning up sudo test files..."
    system "sudo rm -rf #{File.expand_path("../tmp/sudo_gem_home", __FILE__)}"
  end

  # RubyGems specs by version
  namespace :rubygems do
    rubyopt = ENV["RUBYOPT"]
    # When editing this list, also edit .travis.yml!
    branches = %w[master]
    releases = %w[v2.5.2 v2.6.14 v2.7.8 v3.0.2]
    (branches + releases).each do |rg|
      desc "Run specs with RubyGems #{rg}"
      task rg do
        sh("bin/rspec")
      end

      # Create tasks like spec:rubygems:v1.8.3:sudo to run the sudo specs
      namespace rg do
        task :sudo => ["set_sudo", rg, "clean_sudo"]
        task :realworld => ["set_realworld", rg]
      end

      task "clone_rubygems_#{rg}" do
        unless File.directory?(RUBYGEMS_REPO)
          system("git clone https://github.com/rubygems/rubygems.git tmp/rubygems")
        end
        hash = nil

        if RUBYGEMS_REPO.start_with?(Dir.pwd)
          Dir.chdir(RUBYGEMS_REPO) do
            system("git remote update")
            if rg == "master"
              system("git checkout origin/master")
            else
              system("git checkout #{rg}") || raise("Unknown RubyGems ref #{rg}")
            end
            hash = `git rev-parse HEAD`.chomp
          end
        elsif rg != "master"
          raise "need to be running against master with bundler as a submodule"
        end

        puts "Checked out rubygems '#{rg}' at #{hash}"
        ENV["RGV"] = rg
      end

      task rg => ["clone_rubygems_#{rg}"]
      task "rubygems:all" => rg
    end

    desc "Run specs under a RubyGems checkout (set RG=path)"
    task "co" do
      sh("bin/rspec")
    end

    task "setup_co" do
      rg = File.expand_path ENV["RG"]
      puts "Running specs against RubyGems in #{rg}..."
      ENV["RUBYOPT"] = "-I#{rg} #{rubyopt}"
    end

    task "co" => "setup_co"
    task "rubygems:all" => "co"
  end

  desc "Run the tests on Travis CI against a RubyGem version (using ENV['RGV'])"
  task :travis do
    rg = ENV["RGV"] || raise("RubyGems version is required on Travis!")

    # disallow making network requests on CI
    ENV["BUNDLER_SPEC_PRE_RECORDED"] = "TRUE"

    puts "\n\e[1;33m[Travis CI] Running bundler specs against RubyGems #{rg}\e[m\n\n"
    specs = safe_task { Rake::Task["spec:rubygems:#{rg}"].invoke }

    Rake::Task["spec:rubygems:#{rg}"].reenable

    puts "\n\e[1;33m[Travis CI] Running bundler sudo specs against RubyGems #{rg}\e[m\n\n"
    sudos = system("sudo -E rake spec:rubygems:#{rg}:sudo")
    # clean up by chowning the newly root-owned tmp directory back to the travis user
    system("sudo chown -R #{ENV["USER"]} #{File.join(File.dirname(__FILE__), "tmp")}")

    Rake::Task["spec:rubygems:#{rg}"].reenable

    puts "\n\e[1;33m[Travis CI] Running bundler real world specs against RubyGems #{rg}\e[m\n\n"
    realworld = safe_task { Rake::Task["spec:rubygems:#{rg}:realworld"].invoke }

    { "specs" => specs, "sudo" => sudos, "realworld" => realworld }.each do |name, passed|
      if passed
        puts "\e[0;32m[Travis CI] #{name} passed\e[m"
      else
        puts "\e[0;31m[Travis CI] #{name} failed\e[m"
      end
    end

    unless specs && sudos && realworld
      raise "Spec run failed, please review the log for more information"
    end
  end
end

desc "Run RuboCop"
task :rubocop do
  sh("bin/rubocop --parallel")
end
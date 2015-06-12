module Pod
  module Generator
    module XCConfig
      # Generates the xcconfigs for the aggregate targets.
      #
      class AggregateXCConfig
        # @return [Target] the target represented by this xcconfig.
        #
        attr_reader :target

        # Initialize a new instance
        #
        # @param  [Target] target @see target
        #
        # @param  [String] configuration_name
        #         The name of the build configuration to generate this xcconfig
        #         for.
        #
        def initialize(target, configuration_name)
          @target = target
          @configuration_name = configuration_name
        end

        # @return [Xcodeproj::Config] The generated xcconfig.
        #
        attr_reader :xcconfig

        # Generates and saves the xcconfig to the given path.
        #
        # @param  [Pathname] path
        #         the path where the xcconfig should be stored.
        #
        # @return [void]
        #
        def save_as(path)
          generate.save_as(path)
        end

        # Generates the xcconfig.
        #
        # @note   The xcconfig file for a Pods integration target includes the
        #         namespaced xcconfig files for each spec target dependency.
        #         Each namespaced configuration value is merged into the Pod
        #         xcconfig file.
        #
        # @todo   This doesn't include the specs xcconfigs anymore and now the
        #         logic is duplicated.
        #
        # @return [Xcodeproj::Config]
        #
        def generate
          config = {
            'OTHER_LDFLAGS' => '$(inherited) ' + XCConfigHelper.default_ld_flags(target),
            'OTHER_LIBTOOLFLAGS' => '$(OTHER_LDFLAGS)',
            'PODS_ROOT' => target.relative_pods_root,
            'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) COCOAPODS=1',
          }
          @xcconfig = Xcodeproj::Config.new(config)

          generate_settings_to_import_pod_targets

          XCConfigHelper.add_target_specific_settings(target, @xcconfig)

          generate_vendored_build_settings
          generate_other_ld_flags

          # TODO: Need to decide how we are going to ensure settings like these
          # are always excluded from the user's project.
          #
          # See https://github.com/CocoaPods/CocoaPods/issues/1216
          @xcconfig.attributes.delete('USE_HEADERMAP')

          generate_ld_runpath_search_paths if target.requires_frameworks?

          @xcconfig
        end

        #---------------------------------------------------------------------#

        private

        # Add build settings, which ensure that the pod targets can be imported
        # from the integrating target by all sort of imports, which are:
        #  - `#import <…>`
        #  - `#import "…"`
        #  - `@import …` / `@import …;`
        #
        def generate_settings_to_import_pod_targets
          if target.requires_frameworks?
            # Framework headers are automatically discoverable by `#import <…>`.
            header_search_paths = target.pod_targets.map do |target|
              if target.scoped?
                "$PODS_FRAMEWORK_BUILD_PATH/#{target.product_name}/Headers"
              else
                "#{target.product_name}/Headers"
              end
            end
            build_settings = {
              'PODS_FRAMEWORK_BUILD_PATH' => target.configuration_build_dir,
              # Make headers discoverable by `import "…"`
              'OTHER_CFLAGS' => '$(inherited) ' + XCConfigHelper.quote(header_search_paths, '-iquote'),
            }
            if target.pod_targets.any? { |t| t.should_build? && t.scoped? }
              build_settings['FRAMEWORK_SEARCH_PATHS'] = '$(inherited) "$PODS_FRAMEWORK_BUILD_PATH"'
            end
            @xcconfig.merge!(build_settings)
          else
            # Make headers discoverable from $PODS_ROOT/Headers directory
            header_search_paths = target.sandbox.public_headers.search_paths(target.platform)
            build_settings = {
              # by `#import "…"`
              'HEADER_SEARCH_PATHS' => '$(inherited) ' + XCConfigHelper.quote(header_search_paths),
              # by `#import <…>`
              'OTHER_CFLAGS' => '$(inherited) ' + XCConfigHelper.quote(header_search_paths, '-isystem'),
            }
            @xcconfig.merge!(build_settings)
          end
        end

        # Add custom build settings and required build settings to link to
        # vendored libraries and frameworks.
        #
        # @note
        #   In case of generated pod targets, which require frameworks, the
        #   vendored frameworks and libraries are already linked statically
        #   into the framework binary and must not be linked again to the
        #   user target.
        #
        def generate_vendored_build_settings
          target.pod_targets.each do |pod_target|
            unless pod_target.should_build? && pod_target.requires_frameworks?
              XCConfigHelper.add_settings_for_file_accessors_of_target(pod_target, @xcconfig)
            end
          end
        end

        # Add pod target to list of frameworks / libraries that are linked
        # with the user’s project.
        #
        def generate_other_ld_flags
          other_ld_flags = target.pod_targets.select(&:should_build?).map do |pod_target|
            if pod_target.requires_frameworks?
              %(-framework "#{pod_target.product_basename}")
            else
              %(-l "#{pod_target.product_basename}")
            end
          end
          @xcconfig.merge!('OTHER_LDFLAGS' => other_ld_flags.join(' '))
        end

        # Ensure to add the default linker run path search paths as they could
        # be not present due to being historically absent in the project or
        # target template or just being removed by being superficial when
        # linking third-party dependencies exclusively statically. This is not
        # something a project needs specifically for the integration with
        # CocoaPods, but makes sure that it is self-contained for the given
        # constraints.
        #
        def generate_ld_runpath_search_paths
          ld_runpath_search_paths = ['$(inherited)']
          if target.platform.symbolic_name == :osx
            ld_runpath_search_paths << "'@executable_path/../Frameworks'"
            ld_runpath_search_paths << \
              if target.native_target.symbol_type == :unit_test_bundle
                "'@loader_path/../Frameworks'"
              else
                "'@loader_path/Frameworks'"
              end
          else
            ld_runpath_search_paths << [
              "'@executable_path/Frameworks'",
              "'@loader_path/Frameworks'",
            ]
          end
          @xcconfig.merge!('LD_RUNPATH_SEARCH_PATHS' => ld_runpath_search_paths.join(' '))
        end

        #---------------------------------------------------------------------#
      end
    end
  end
end

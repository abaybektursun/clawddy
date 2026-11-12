#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment.
# All mutable build products and caches live on external storage so a failed or
# repeated build cannot fill the internal system disk.

const default_build_root = "/Volumes/Xcode/GhosttyBuilds/ghostty/macos"

def external-root [override?: string] {
    let root = (
        $override
        | default ($env.GHOSTTY_MACOS_BUILD_ROOT?
            | default $default_build_root)
        | path expand)
    if not ($root | str starts-with "/Volumes/") {
        error make {
            msg: $"External build root must be under /Volumes, got: ($root)"
        }
    }
    let parts = ($root | path split)
    let volume = ($parts | first 3 | path join)
    if not ($volume | path exists) {
        error make {
            msg: $"External build volume is not mounted: ($volume)"
        }
    }
    $root
}

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Release" # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --identity: string = "production"  # App identity (production, dev); tests always use their own
    --build-root: string                # Override GHOSTTY_MACOS_BUILD_ROOT
    --show-paths                        # Print resolved storage paths without building
] {
    if $identity not-in ["production" "dev"] {
        error make { msg: $"Unknown identity ($identity); expected production or dev" }
    }
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let root = (external-root $build_root)
    # A test run always builds the test identity, whatever --identity says, so
    # a test host never shares a bundle ID, data folder or products with a
    # runnable app. Each identity has its own build graph, so building one can
    # never mutate another's product or incremental state. Tests also need an
    # @testable Release module with XCTest frameworks injected into the app.
    let build_identity = if $action == "test" { "test" } else { $identity }
    let action_root = match $build_identity {
        "test" => ($root | path join "tests")
        "dev" => ($root | path join "dev")
        _ => $root
    }
    let products = ($action_root | path join "products")
    let objects = ($action_root | path join "objects")
    let derived_data = ($action_root | path join "DerivedData")
    let source_packages = ($root | path join "SourcePackages")
    let package_cache = ($root | path join "PackageCache")
    let module_cache = ($action_root | path join "ModuleCache.noindex")
    let shared_precomps = ($action_root | path join "SharedPrecompiledHeaders")
    let compilation_cache = ($action_root | path join "CompilationCache.noindex")
    let destination = ($action_root | path join "Destination")
    let temporary = ($action_root | path join "tmp")
    let zig_local_cache = ($root | path join "zig-cache" "local")
    let zig_global_cache = ($root | path join "zig-cache" "global")
    let code_sign_identity = ($env.GHOSTTY_CODE_SIGN_IDENTITY?
        | default "Apple Development")
    let development_team = ($env.GHOSTTY_DEVELOPMENT_TEAM?
        | default "94DS9XB3FJ")

    mkdir $products $objects $derived_data $source_packages $package_cache
    mkdir $module_cache $shared_precomps $compilation_cache $destination
    mkdir $temporary $zig_local_cache $zig_global_cache

    # SYMROOT, OBJROOT, and DSTROOT live outside DerivedData. Because this
    # wrapper creates them, Xcode cannot otherwise prove that its `clean`
    # action owns them and refuses to remove stale products. Mark only these
    # dedicated build roots as Xcode-created; they never contain source or
    # user data.
    (^xattr -w com.apple.xcode.CreatedByBuildSystem true
        $products $objects $destination)

    if $show_paths {
        print ({
            identity: $build_identity
            build_root: $root
            app: ($products | path join $configuration "Ghostty.app")
            objects: $objects
            derived_data: $derived_data
            source_packages: $source_packages
            package_cache: $package_cache
            module_cache: $module_cache
            compilation_cache: $compilation_cache
            temporary: $temporary
            code_sign_identity: $code_sign_identity
            development_team: $development_team
        } | table --expand)
        return
    }

    # Unit tests import the app with @testable. The test-only Release graph is
    # optimized but must explicitly emit a testable module; it is never used as
    # the runnable production bundle. Restrict the action to unit tests so
    # Xcode does not build or launch the permission-gated UI-test target.
    let test_arguments = if $action == "test" {
        ["-only-testing:GhosttyTests" "ENABLE_TESTABILITY=YES"]
    } else {
        []
    }

    # The bundle ID separates preferences, notifications and permissions; the
    # data folder name selects ~/.config/<name>. The production identity uses
    # the project's own values. The app enables the global hot key and the
    # updater only under the production bundle ID.
    let identity_arguments = match $build_identity {
        "test" => [
            "CLAWDDY_BUNDLE_IDENTIFIER=com.mitchellh.ghostty.clawddy-tests"
            "CLAWDDY_DATA_DIRECTORY_NAME=clawddy-tests"
        ]
        "dev" => [
            "CLAWDDY_BUNDLE_IDENTIFIER=com.mitchellh.ghostty.clawddy-dev"
            "CLAWDDY_DISPLAY_NAME=Clawddy Dev"
            "CLAWDDY_DATA_DIRECTORY_NAME=clawddy-dev"
        ]
        _ => []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        $"TMPDIR=($temporary)/"
        $"ZIG_LOCAL_CACHE_DIR=($zig_local_cache)"
        $"ZIG_GLOBAL_CACHE_DIR=($zig_global_cache)"
        $"COMPILATION_CACHE_CAS_PATH=($compilation_cache)"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        -derivedDataPath $derived_data
        -clonedSourcePackagesDirPath $source_packages
        -packageCachePath $package_cache
        -packageAuthorizationProvider netrc
        $"SYMROOT=($products)"
        $"OBJROOT=($objects)"
        $"DSTROOT=($destination)"
        $"MODULE_CACHE_DIR=($module_cache)"
        $"SHARED_PRECOMPS_DIR=($shared_precomps)"
        $"COMPILATION_CACHE_CAS_PATH=($compilation_cache)"
        $"CODE_SIGN_IDENTITY=($code_sign_identity)"
        $"DEVELOPMENT_TEAM=($development_team)"
        ...$test_arguments
        ...$identity_arguments
        $action)
}

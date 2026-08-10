#!/usr/bin/env nu

# Run Zig builds with every mutable output on external storage. The wrapper
# deliberately fails when the configured volume is unavailable rather than
# silently filling the internal system disk.

const default_build_root = "/Volumes/Xcode/GhosttyBuilds/ghostty"

def external-root [override?: string] {
    let root = (
        $override
        | default ($env.GHOSTTY_BUILD_ROOT? | default $default_build_root)
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
    --build-root: string  # Override GHOSTTY_BUILD_ROOT for an isolated build
    --show-paths          # Print resolved storage paths without building
    ...arguments: string  # Arguments passed to `zig build`
] {
    let root = (external-root $build_root)
    let zig_root = ($root | path join "zig")
    let prefix = ($zig_root | path join "prefix")
    let local_cache = ($zig_root | path join "cache" "local")
    let global_cache = ($zig_root | path join "cache" "global")
    let temporary = ($root | path join "tmp")
    let compatibility_output = ($env.FILE_PWD | path join "zig-out")

    mkdir $prefix $local_cache $global_cache $temporary

    if ($compatibility_output | path exists) {
        if ($compatibility_output | path type) != "symlink" {
            error make {
                msg: $"Refusing to replace local build output: ($compatibility_output)"
            }
        }
        let target = (^/usr/bin/readlink $compatibility_output | str trim)
        if $target != $prefix {
            error make {
                msg: $"zig-out points outside the configured build root: ($target)"
            }
        }
    } else {
        ^/bin/ln -s $prefix $compatibility_output
    }

    if $show_paths {
        print ({
            build_root: $root
            install_prefix: $prefix
            local_cache: $local_cache
            global_cache: $global_cache
            temporary: $temporary
            compatibility_output: $compatibility_output
        } | table --expand)
        return
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        $"TMPDIR=($temporary)/"
        $"ZIG_LOCAL_CACHE_DIR=($local_cache)"
        $"ZIG_GLOBAL_CACHE_DIR=($global_cache)"
        zig build
        --prefix $prefix
        ...$arguments)
}

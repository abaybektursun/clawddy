#!/usr/bin/env nu

# Run Zig builds with every mutable output on external storage. The wrapper
# deliberately fails when the configured volume is unavailable rather than
# silently filling the internal system disk.
#
# Two upstream paths still resolve inside the worktree when the macOS library
# is built: `zig-out` and `macos/GhosttyKit.xcframework`. Xcode links against
# the XCFramework, so that path has to keep working, but its real contents are
# relocated to the external build root and the worktree keeps only a symlink.

const default_build_root = "/Volumes/Xcode/GhosttyBuilds/ghostty"
const xcframework_name = "GhosttyKit.xcframework"

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

# Resolve the compiler before the sealed environment is constructed. Zig 0.17
# is usually not the `zig` on PATH, so GHOSTTY_ZIG selects it explicitly. The
# selected executable is invoked by path; no shell text is evaluated.
def resolve-zig [] {
    let explicit = ($env.GHOSTTY_ZIG? | default "" | str trim)
    let candidate = if ($explicit | is-empty) {
        which zig | get --optional 0 | get --optional path
    } else {
        $explicit | path expand
    }
    if ($candidate | is-empty) {
        error make {
            msg: "No Zig compiler found: set GHOSTTY_ZIG or put zig on PATH"
        }
    }
    if not ($candidate | path exists) {
        error make {
            msg: $"Zig compiler does not exist: ($candidate)"
        }
    }
    if (path-kind $candidate) == "dir" {
        error make {
            msg: $"Zig compiler is a directory: ($candidate)"
        }
    }
    let probe = (do -i { ^$candidate version } | complete)
    if $probe.exit_code != 0 {
        error make {
            msg: $"Zig compiler cannot run: ($candidate)"
        }
    }
    let version = ($probe.stdout | str trim)
    { path: $candidate, version: $version }
}

# `path type` returns nothing instead of failing for a missing path.
def path-kind [path: string] {
    let kind = (try { $path | path type } catch { null })
    if ($kind | is-empty) { "missing" } else { $kind }
}

# Move a real artifact aside under a fresh name so no existing data is
# overwritten or deleted.
def preserve-artifact [artifact: string, archive_dir: string, label: string] {
    mkdir $archive_dir
    let stamp = (date now | format date "%Y%m%d-%H%M%S")
    mut destination = ($archive_dir | path join $"($label)-($stamp)")
    mut attempt = 1
    while (path-kind $destination) != "missing" {
        $destination = ($archive_dir | path join $"($label)-($stamp)-($attempt)")
        $attempt = $attempt + 1
    }
    ^/bin/mv $artifact $destination
    print $"Preserved ($artifact) at ($destination)"
}

# `src/build/GhosttyXCFramework.zig` names `macos/GhosttyKit.xcframework` as a
# source-tree output, so xcodebuild writes the product inside the worktree.
# Make the Xcode-visible path a symlink to external storage before the build;
# the upstream delete step then removes only the link.
def prepare-xcframework [link: string, external: string, archive_dir: string] {
    mkdir ($external | path dirname)
    let kind = (path-kind $link)
    if $kind == "symlink" {
        let target = (^/usr/bin/readlink $link | str trim)
        if $target != $external {
            error make {
                msg: $"XCFramework symlink points outside the build root: ($link) -> ($target)"
            }
        }
    } else if $kind == "dir" {
        # A pre-existing real artifact: relocate it instead of deleting it.
        if (path-kind $external) == "missing" {
            ^/bin/mv $link $external
        } else {
            preserve-artifact $link $archive_dir $xcframework_name
        }
    } else if $kind != "missing" {
        error make {
            msg: $"Refusing to replace unexpected XCFramework path: ($link) is ($kind)"
        }
    }
    if (path-kind $link) == "missing" {
        ^/bin/ln -s $external $link
    }
}

# After the build, restore the external-storage layout. xcodebuild replaces the
# symlink with a real directory, so fail loudly rather than leaving real build
# products in the worktree.
def restore-xcframework [link: string, external: string, root: string] {
    let history = ($root | path join "xcframework" "history")
    let kind = (path-kind $link)
    if $kind == "symlink" {
        let target = (^/usr/bin/readlink $link | str trim)
        if $target != $external {
            error make {
                msg: $"XCFramework symlink points outside the build root: ($link) -> ($target)"
            }
        }
        return
    }
    if $kind == "missing" {
        if (path-kind $external) == "missing" {
            error make {
                msg: $"Build produced no XCFramework at ($link) or ($external)"
            }
        }
        ^/bin/ln -s $external $link
        return
    }
    if $kind != "dir" {
        error make {
            msg: $"Refusing to relocate unexpected XCFramework path: ($link) is ($kind)"
        }
    }

    let staging = ($root | path join "xcframework" "staging")
    mkdir $staging
    let staged = ($staging | path join $xcframework_name)
    if (path-kind $staged) != "missing" {
        preserve-artifact $staged $history $xcframework_name
    }
    ^/bin/mv $link $staged
    if (path-kind $external) != "missing" {
        preserve-artifact $external $history $xcframework_name
    }
    ^/bin/mv $staged $external
    ^/bin/ln -s $external $link
    print $"XCFramework relocated to external storage: ($external)"
}

def --wrapped main [
    --build-root: string  # Override GHOSTTY_BUILD_ROOT for an isolated build
    --show-paths          # Print resolved storage paths without building
    ...arguments: string  # Arguments passed to `zig build`
] {
    let root = (external-root $build_root)
    let zig_root = ($root | path join "zig")
    let prefix = ($zig_root | path join "prefix")
    let local_cache = ($zig_root | path join "cache" "local")
    let global_cache = ($zig_root | path join "cache" "global")
    let package_cache = ($zig_root | path join "pkg")
    let temporary = ($root | path join "tmp")
    let compatibility_output = ($env.FILE_PWD | path join "zig-out")
    let xcframework_link = ($env.FILE_PWD | path join "macos" $xcframework_name)
    let xcframework_external = ($root | path join "xcframework" $xcframework_name)
    let xcframework_history = ($root | path join "xcframework" "history")
    let zig = (resolve-zig)

    mkdir $prefix $local_cache $global_cache $package_cache $temporary

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
            zig: $zig.path
            zig_version: $zig.version
            install_prefix: $prefix
            local_cache: $local_cache
            global_cache: $global_cache
            package_cache: $package_cache
            temporary: $temporary
            compatibility_output: $compatibility_output
            xcframework_link: $xcframework_link
            xcframework_external: $xcframework_external
        } | table --expand)
        return
    }

    prepare-xcframework $xcframework_link $xcframework_external $xcframework_history

    let build_failure = (try {
        (^env -i
            $"HOME=($env.HOME)"
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            $"TMPDIR=($temporary)/"
            $"ZIG_LOCAL_CACHE_DIR=($local_cache)"
            $"ZIG_GLOBAL_CACHE_DIR=($global_cache)"
            $"ZIG_LOCAL_PKG_DIR=($package_cache)"
            $zig.path
            build
            --prefix $prefix
            ...$arguments)
        null
    } catch {|e| $e })

    # Restore the layout even after a failed build so a broken build cannot
    # leave the real framework behind in the worktree.
    let restore_failure = (try {
        restore-xcframework $xcframework_link $xcframework_external $root
        null
    } catch {|e| $e })

    if $build_failure != null {
        let restore_note = if $restore_failure != null {
            $" The XCFramework could not be moved to external storage either: ($restore_failure.msg)."
        } else {
            ""
        }
        error make {
            msg: $"zig build failed with exit code ($build_failure.exit_code).($restore_note)"
        }
    }
    if $restore_failure != null {
        error make {
            msg: $"zig build succeeded but the XCFramework could not be moved to external storage: ($restore_failure.msg). Real build products may remain at ($xcframework_link)"
        }
    }
}

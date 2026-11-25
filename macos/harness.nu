#!/usr/bin/env nu

const default_app = "/Volumes/Xcode/GhosttyBuilds/ghostty/macos/dev/products/Release/Ghostty.app"
const last_file = "/Volumes/Xcode/GhosttyBuilds/ghostty/harness/last"

# Runs Clawddy Dev as a harness: in the background, never the active app and
# with no window on screen, on data written from a scene, driven through a
# Unix socket. The app's side is AgentHarness.swift.
#
#   macos/harness.nu start <scene.json> <dir> [--real] [--app <Ghostty.app>]
#                                                       start the app on <dir>
#   macos/harness.nu send '<json>' [--dir <dir>]        one request, prints the reply
#   macos/harness.nu shot <file.png> [--dir <dir>]      a picture of the window
#   macos/harness.nu stop [--dir <dir>]                 quit it
#
# The scene with the prototype's agents: Tests/AgentManagement/Scenes/prototype.json.
# --real runs the real `claude` and `codex` from the login-shell PATH instead
# of the stand-ins: the scene's sessions, stand-in scripts and "command" are
# left out, so each running agent starts a new session of the real CLI in
# <dir>/work/<project>. The real CLIs keep their own files where they always
# do (~/.claude, ~/.codex), outside <dir>.
#
# <dir> must be on the external disk, e.g.
# /Volumes/Xcode/GhosttyBuilds/ghostty/harness/run1. `send` and `stop` use the
# folder `start` last used unless --dir names another. A second `start` on a
# folder whose data exists is a restart: the data is kept and the scene only
# selects the agent.
#
# What <dir> holds: scene.json (the scene), root/ (the app's data root),
# work/<project>/ (project folders), bin/ (claude and codex, first on the PATH
# of agent terminals), standin/<session id>.json, ghostty.conf, control.sock,
# pid, app (the bundle it runs), preferences.plist (the run's preferences,
# in place of the bundle ID's: the window's saved frame and the workspace's
# drafts, densities and views, kept across a restart as a normal launch keeps
# them). The window opens as a normal launch opens it (the saved frame, else
# the default), or at the scene's "window" size on the first start. The app
# logs to the unified log (subsystem com.mitchellh.ghostty).
#
# Scene format (JSON; plain, no comments):
#
#   {
#     "command": "/bin/cat",        optional: bin/claude and bin/codex become
#                                   scripts that run this program instead of
#                                   the stand-ins
#     "selected": "Tom",            optional: the selected agent, by name or
#                                   "project/name"
#     "window": [1280, 800],        optional: the window's size in points
#     "projects": [
#       {
#         "name": "cats",           its folder is <dir>/work/cats
#         "agents": [
#           {
#             "name": "Tom",
#             "provider": "claudeCode",   or "codex"; default claudeCode
#             "session": "<id>",          optional: the saved session its
#                                         launch resumes (letters, digits, - _ .)
#             "running": true,            optional: its CLI starts when the harness
#                                         first starts on this folder
#             "unread": true,             optional: a finished turn not yet seen
#             "autoNamed": true,          optional: its name is Clawddy's
#             "launchProfile": {"startMode": "unrestricted", "modelID": null,
#                               "reasoningEffort": null},    optional
#             "standin": { ... }          optional, needs "session": written as
#                                         it is to standin/<session>.json for the
#                                         stand-in CLI (its format: the comment
#                                         at the top of Tests/AgentManagement/StandIns/claude)
#             "record": { ... }           optional: any fields of its record
#                                         (AgentRecord.swift), dates ISO 8601,
#                                         e.g. {"state":"asks","question":"A?",
#                                         "prompts":[{"text":"go","at":"2026-11-23T10:00:00Z","by":"person"}]}
#             "state": "finished",        optional, the prototype's short keys,
#                                         over "record": working, finished, asks,
#                                         failed or paused; "settled": true;
#                                         "sentence" (the finished agent's last
#                                         message, the question, the problem's or
#                                         the limit's text); "firstInstruction";
#                                         "step" (what a working agent does);
#                                         "ageSeconds" (since its state changed)
#             ...                         any other key is ignored (branch)
#           }
#         ]
#       }
#     ]
#   }
#
# Without "command", bin/ gets the stand-ins from
# macos/Tests/AgentManagement/StandIns when they exist.
#
# Requests (one JSON object, one command):
#   {"state":true}                          one object: selected, project,
#                                           openProjects, focus (sidebar, terminal,
#                                           field, window), firstResponder
#                                           (terminal:<agent>, field, window, none,
#                                           or a class), scale, notifications,
#                                           windows, and per agent: mark (waiting,
#                                           done, working, starting, problem,
#                                           notRunning), busy, headline, reason,
#                                           unread, running, inputReady (its CLI
#                                           reads its input), heldKeys (keys held
#                                           while it starts), process, surface
#                                           (visible: shown and drawing;
#                                           occluded: hidden, drawing stopped;
#                                           shown-occluded: the window is not
#                                           seen; detached or hidden-drawing:
#                                           a broken invariant; none), focused
#                                           (Ghostty's focus), terminal (points,
#                                           cells, mouseOver, mouseAt), text,
#                                           record (the stored record as JSON),
#                                           sentence, sentenceByApp (the app's
#                                           words, set in italic);
#                                           also frontmost and activations (must
#                                           stay false and 0), active (AppKit's
#                                           own flag, true for a moment while a
#                                           panel becomes key), hidden,
#                                           sidebarHidden, providers
#                                           (the claude and codex each launch finds)
#   {"key":"cmd+]"}                         a key press: modifiers cmd shift opt
#                                           ctrl, then a character or return,
#                                           escape, tab, space, delete, up, ...
#   {"type":"hello"}                        one key per character (US keys)
#   {"keys":{"chords":["return","cmd+escape"],"gaps":[0,5]}}
#                                           key presses in quick succession, each
#                                           after its gap in ms (0: the same turn)
#   {"click":{"x":10,"y":20,"count":1,"modifiers":"cmd","button":"left"}}
#                                           points from the window's top left
#   {"drag":{"from":[x,y],"to":[x,y],"steps":10}}  "release":false keeps the button down
#   {"move":{"from":[x,y],"to":[x,y],"steps":10}}  the pointer moving, no button
#   {"resize":{"width":1100,"height":700}}  the window's size in points
#   {"send":{"agent":"Tom","text":"hi","by":"app","interrupt":false}}
#                                           text into that agent's CLI through
#                                           the app's one send (paste, Return),
#                                           shown or not, recorded as by "app"
#                                           or "person"; result: sent, holdsText,
#                                           menu or notReady
#   {"open":"Tom"}                          opens the agent on purpose: shown,
#                                           its CLI started if it is not running
#   {"start":{"project":"cats","task":"fix it","provider":"codex"}}
#                                           a new agent from a typed task; name
#   {"settle":"Tom"}                        settles the agent (working ones too)
#   {"cancel":"Tom"}                        cancels a start within 6 s;
#                                           cancelled: false when too late
#   {"wait":{"agent":"Tom","text":"hi","timeout":5}}
#                                           until every key matches the agent's
#                                           entry (or the top of the state
#                                           without "agent"); text: contains
#   {"shot":"shots/home.png"}               the whole window at its backing scale,
#                                           terminals included, sRGB PNG; the path
#                                           is under <dir> (relative paths are)
#   {"frames":{"prefix":"shots/grow","action":{"key":"cmd+ctrl+s"},"ms":200,"step":16}}
#                                           the action with animations held at
#                                           their start, then a picture every step
#                                           of animation time: prefix-000.png ...
#                                           and prefix-strip.png at a quarter size.
#                                           Core Animation only: AppKit's own
#                                           animations (the sidebar sliding) are
#                                           not stepped and do not run at all
#                                           while the screen is locked
#   {"quitQuestion":true}                   what ⌘Q would ask now, without asking:
#                                           asks (clawddy, ghostty, nothing), notice
#   {"quit":true}                           quits without asking (how `stop` ends a run)
# A terminal's text is Ghostty's read text, refreshed at most every 500 ms:
# wait for it rather than reading it once.
def main [] {
    help main
}

# A folder on the external disk, which must be mounted.
def external [dir: string] {
    let dir = ($dir | path expand)
    if not ($dir | str starts-with "/Volumes/") {
        error make { msg: $"The harness folder must be on the external disk under /Volumes, not ($dir)" }
    }
    let volume = ($dir | path split | first 3 | path join)
    if not ($volume | path exists) {
        error make { msg: $"External volume is not mounted: ($volume)" }
    }
    $dir
}

def harness-dir [dir?: string] {
    if $dir != null { return (external $dir) }
    if not ($last_file | path exists) {
        error make { msg: "No harness started yet; pass --dir" }
    }
    external (open $last_file | str trim)
}

# The bundle the harness on <dir> runs.
def harness-app [dir: string] {
    let file = ($dir | path join "app")
    if ($file | path exists) { open $file | str trim } else { $default_app }
}

# The pid the app wrote, when that process is still this app.
def running-pid [dir: string] {
    let app = (harness-app $dir)
    let pid_file = ($dir | path join "pid")
    if not ($pid_file | path exists) { return null }
    let pid = (open $pid_file | str trim | into int)
    let executable = (^ps -p $pid -o comm= | complete)
    if $executable.exit_code != 0 { return null }
    if ($executable.stdout | str trim) != ($app | path join "Contents/MacOS/ghostty") {
        return null
    }
    $pid
}

# Start Clawddy Dev in the background on <dir>, seeded from <scene>.
def "main start" [
    scene: path   # the scene file (format: macos/harness.nu --help)
    dir: string   # the harness folder, on the external disk
    --real        # the real CLIs instead of the stand-ins
    --app: string # the Ghostty.app to run (default: the Release build of macos/build.nu)
] {
    let dir = (external $dir)
    let app = ($app | default $default_app | path expand)
    if not ($app | path exists) {
        error make { msg: $"No Release build at ($app); run macos/build.nu" }
    }
    let running = (running-pid $dir)
    if $running != null {
        error make { msg: $"A harness already runs on ($dir) as pid ($running)" }
    }
    mkdir $dir
    let contents = if $real {
        open $scene | reject --optional command | update projects {|scene|
            $scene.projects | each {|project|
                $project | update agents ($project.agents | each {|agent| $agent | reject --optional session standin })
            }
        }
    } else {
        open $scene
    }
    $contents | to json | save -f ($dir | path join "scene.json")

    let bin = ($dir | path join "bin")
    mkdir $bin
    let command = ($contents | get --optional command)
    let standins = ($env.FILE_PWD | path join "Tests/AgentManagement/StandIns")
    for cli in ["claude" "codex"] {
        let target = ($bin | path join $cli)
        rm -f $target
        if $real {
            # Found on the login-shell PATH after bin/.
        } else if $command != null {
            $"#!/bin/sh\nexec ($command)\n" | save $target
            ^chmod 755 $target
        } else if ($standins | path join $cli | path exists) {
            ^cp -L ($standins | path join $cli) $target
            ^chmod 755 $target
        }
    }

    # The owner's Ghostty configuration is not read. Quitting asks nothing.
    # A program's desktop notification (OSC 9/777) would reach the person's
    # screen, or ask them for permission, so terminals may not post one.
    "confirm-close-surface = false\ndesktop-notifications = false\n" | save -f ($dir | path join "ghostty.conf")
    rm -f ($dir | path join "pid")
    $app | save -f ($dir | path join "app")
    $dir | save -f $last_file

    (^env -u NO_COLOR open -g -n
        --env $"CLAWDDY_HARNESS=($dir)"
        -a $app
        --args --config-default-files=false $"--config-file=($dir | path join 'ghostty.conf')")

    let deadline = (date now) + 30sec
    loop {
        let pid = (running-pid $dir)
        if $pid != null and ($dir | path join "control.sock" | path exists) {
            print $"started pid ($pid) on ($dir)"
            return
        }
        if (date now) > $deadline {
            error make { msg: $"The app did not start on ($dir) within 30 s" }
        }
        sleep 100ms
    }
}

# Send one JSON request and print the reply.
def "main send" [
    request: string   # one JSON object, e.g. '{"state":true}'
    --dir: string     # the harness folder; default: the one last started
] {
    let dir = (harness-dir $dir)
    # nc waits up to an hour for the reply; the app closes the connection
    # once it has answered.
    let reply = ($"($request)\n" | ^nc -w 3600 -U ($dir | path join "control.sock"))
    print ($reply | str trim)
}

# Save a picture of the whole window as PNG; the file must be under the
# harness folder.
def "main shot" [
    file: path      # where the PNG goes, under the harness folder
    --dir: string   # the harness folder; default: the one last started
] {
    let dir = (harness-dir $dir)
    let request = ({shot: ($file | path expand)} | to json --raw)
    main send $request --dir $dir
}

# Quit the app started on the folder, and only that process.
def "main stop" [
    --dir: string   # the harness folder; default: the one last started
] {
    let dir = (harness-dir $dir)
    let pid = (running-pid $dir)
    if $pid == null {
        print $"nothing runs on ($dir)"
        return
    }
    "{\"quit\":true}\n" | ^nc -w 3600 -U ($dir | path join "control.sock") | ignore
    let deadline = (date now) + 10sec
    loop {
        if (^ps -p $pid | complete).exit_code != 0 {
            print $"stopped pid ($pid)"
            return
        }
        if (date now) > $deadline { break }
        sleep 100ms
    }
    # It did not quit: end that pid, which `running-pid` matched to this app.
    ^kill $pid
    print $"killed pid ($pid)"
}

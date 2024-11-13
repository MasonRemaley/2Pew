# 2Pew

2D Spaceship Dogfighting Arcade Game

## Status

Mainly experiments but there's a playable demo.

# Building from Source

1. Before cloning, ensure that your `git` command has
   [git LFS](https://github.com/git-lfs/git-lfs) enabled. One typically installs
   it via the system package manager, and then runs `git lfs install` once to
   set it up. If you've already cloned the repo before installing, you'll need
   to also run `git lfs pull` to get the missing files.
2. Obtain [Zig](https://ziglang.org/). The latest version from the download
   page should suffice. The `build.zig.zon` file tracks the minimum required
   version.
3. If you're on Linux, install the system SDL2 package.
4. `zig build run`

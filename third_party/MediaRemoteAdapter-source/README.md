# MediaRemote Adapter

MediaRemote Adapter reads Now Playing information and controls media playback through macOS MediaRemote. It exposes a JSON command-line interface through a Perl script and a native framework.

Upstream: [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)

Included revision: [`dc3ff1740e2035a2490ec67d3b33322449af780a`](https://github.com/ungive/mediaremote-adapter/tree/dc3ff1740e2035a2490ec67d3b33322449af780a)

## Build

From this directory:

```sh
cmake -S . -B build
cmake --build build
```

CMake produces `MediaRemoteAdapter.framework` and `MediaRemoteAdapterTestClient` for `arm64` and `x86_64`.

## Usage

Read the current track:

```sh
/usr/bin/perl bin/mediaremote-adapter.pl "$PWD/build/MediaRemoteAdapter.framework" get
```

Stream playback updates:

```sh
/usr/bin/perl bin/mediaremote-adapter.pl "$PWD/build/MediaRemoteAdapter.framework" stream
```

The adapter also provides playback, seeking, shuffle, repeat, and speed commands. See the [upstream command reference](https://github.com/ungive/mediaremote-adapter/blob/dc3ff1740e2035a2490ec67d3b33322449af780a/README.md#commands).

## License

BSD 3-Clause. See [LICENSE](LICENSE).

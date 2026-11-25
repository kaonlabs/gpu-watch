# GPU Watch

GPU Watch is a native macOS menu bar app for finding idle NVIDIA GPUs on machines you can reach over SSH. The chip shows how many GPUs are free. Click it to see one row per machine and one column per GPU.

Green checkmarks mark free cards. Blue highlights show GPUs used by your SSH login on each machine, including GPUs you share. The outer ring shows GPU load and the inner ring shows VRAM usage. Hover over a dial for exact readings and owners, or click to pin its details. Click a machine name to see the GPU numbers assigned to each user and the numbers of the free cards.

## Quick start

1. Download and unzip **GPU Watch** from [Releases](https://github.com/kaonlabs/gpu-watch/releases/latest). The same app runs on Apple silicon and Intel Macs.
2. Create the directory `~/.config/gpu-watch` if needed. Open or create `~/.config/gpu-watch/hosts` in a text editor and add one SSH alias or hostname per line. Blank lines and comments starting with `#` are allowed. Replace these example names with hosts from your own SSH config.

   ```text
   gpu2
   gpu10
   ```

3. Open **GPU Watch.app**. It checks immediately and refreshes every minute, querying up to 16 hosts at once. Use **Refresh** to check on demand.

GPU Watch requires macOS 13 or later and `python3` on your Mac. Each remote machine needs `python3` and NVIDIA's `nvidia-smi` on its PATH. The app uses your existing SSH configuration, known hosts, and credentials. Verify that aliases work with `ssh -o BatchMode=yes gpu2 true`, substituting your own alias. If login needs a passphrase, load your key into your SSH agent first.

The release app is ad hoc signed. If macOS blocks the download, you can build and run the app locally with the steps below.

## Build and modify

With Xcode Command Line Tools installed, run:

```sh
git clone https://github.com/kaonlabs/gpu-watch.git
cd gpu-watch
./build.sh
open "GPU Watch.app"
```

The build targets your Mac's architecture by default. Set `GPU_WATCH_ARCHS="arm64 x86_64"` when building a universal app. Edit `GPUWatch.swift` for the interface, `GPUCheck.swift` for polling and decoding, or `check_gpu_util` for SSH collection. You can run the checker by itself with the configured hosts or give it SSH aliases directly.

```sh
./check_gpu_util
./check_gpu_util --json gpu2 gpu10
```

A card is marked idle when the query confirms 0% utilization, at most 16 MiB used, no GPU processes, and disabled or unavailable MIG mode. A card can be busy at 0% utilization if it still has running processes. The app shows unavailable hosts and unknown readings explicitly.

Forks, issues, and pull requests are welcome. GPU Watch is [MIT licensed](LICENSE).

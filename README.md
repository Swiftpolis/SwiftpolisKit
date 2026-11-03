# SwiftpolisKit

The engines, storage and rules behind [Swiftpolis](https://github.com/OWNER/Swiftpolis), a native download
manager for macOS. It has no user interface.

| Library | What it holds |
| --- | --- |
| `SwiftpolisDomain` | Plain types: statuses, schedule times, requests |
| `SwiftpolisPersistence` | The SwiftData library and its repositories |
| `SwiftpolisEngines` | The HTTP and yt-dlp download engines |
| `SwiftpolisServices` | Queues, schedules, drafts, preferences and the update check |
| `SwiftpolisBridge` | How browsers hand links to the app. It's shared with the extension and helper, so it stays small |

## Use it

It needs macOS 27 and Swift 6.2 or later. The app includes this package as a Git submodule, and uses it as a
local package. It's built for that app, so its interfaces can change between commits.

## Tests

```bash
swift test
```

Tests that need the app's repository, such as those that run the Safari extension's script or the bundled
yt-dlp, are skipped when this package is checked out alone.

## License

Free software under the [GNU General Public License, version 3](LICENSE).

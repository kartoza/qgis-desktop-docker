// Package all imports all the backends
package all

// Replaces backend/all/all.go in the rclone build. See flake.nix.
//
// Upstream registers roughly seventy backends here by side-effect import, and
// every one of them drags its client library into the binary — which is why the
// SBOM for a QGIS desktop listed ProtonMail, Dropbox, Mega, Yandex and the rest.
// None of it was reachable: config/persist/persist.sh accepts exactly two
// values for QGIS_DESKTOP_PERSIST_TYPE, and rejects anything else.
//
// So the list here is the list persist.sh validates, and nothing more.
// scripts/test-persist.sh asserts the two stay in step, because a backend added
// to the shell script without being added here would fail at runtime with a
// confusing "didn't find backend" rather than at build time.
//
// The s3 backend covers every S3-compatible provider — AWS, MinIO, Ceph,
// Wasabi, Backblaze — because the provider is a config key, not a separate
// backend. Nothing is lost by trimming the rest.

import (
	// Object storage, for the home-directory sync.
	_ "github.com/rclone/rclone/backend/s3"

	// The local filesystem, used by the tests and by
	// QGIS_DESKTOP_PERSIST_TYPE=local.
	_ "github.com/rclone/rclone/backend/local"
)

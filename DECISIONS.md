# Decisions

## Universal S3 Doom layout

The selected image shape is: "One 8 MB image, both slots shrunk".

The universal S3 partition table therefore keeps two 2,031,616-byte OTA slots,
places the 4,198,400-byte `doom_wad` partition at `0x3FF000`, and ends exactly
at the 8 MiB flash boundary.

Previously flashed S3 boards need one USB reflash because the partition table
changed, and old-layout OTA is refused.

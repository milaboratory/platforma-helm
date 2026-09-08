#!/usr/bin/env python3
"""Pin the preview template's chart, image and asset-base parameter defaults.

Does not talk to ECR or S3. Used by pl's publish-infra job so the copy under
pr/<version>/ deploys the chart, image and assets that job just published
without the operator retyping any of them.

The image is optional: build-docker.yaml pushes an image for a commit only when
that commit changes what goes into one, so a branch whose latest commits touch
only the chart has no image under the current version. Passing an empty value
leaves PlatformaImage empty, which selects the chart's appVersion image — the
released application — rather than pinning a tag no registry can serve.

Only parameter defaults are pinned, never Mappings DeployerAssets.Public.BaseUrl:
the deployer reads an s3:// base with its own credentials and is granted
s3:GetObject from that same parameter, so clearing the parameter has to fall
back to the published public assets rather than to an unreadable prefix.
"""

import re
import sys
from pathlib import Path


def pin_default(text, parameter, value):
    anchor = re.compile(
        r"(?m)^(  %s:\n(?:    .*\n)*?    Default: )''$" % re.escape(parameter)
    )
    pinned, count = anchor.subn(lambda m: "%s'%s'" % (m.group(1), value), text)
    if count != 1:
        sys.exit(
            "found %d empty Default for %s; refusing to write an unpinned copy"
            % (count, parameter)
        )
    print("pinned %s -> %s" % (parameter, value))
    return pinned


def main():
    if len(sys.argv) != 7:
        sys.exit(
            "usage: pin-preview-chart.py TEMPLATE CHART_REFERENCE VERSION"
            " ASSET_BASE IMAGE DEST"
        )
    src, chart_reference, version, asset_base, image, dest = sys.argv[1:7]
    text = Path(src).read_text()
    text = pin_default(text, "PlatformaHelmChart", chart_reference)
    text = pin_default(text, "PlatformaVersion", version)
    text = pin_default(text, "DeployerAssetBaseUrl", asset_base)
    if image:
        text = pin_default(text, "PlatformaImage", image)
    else:
        print("no image for this version; PlatformaImage stays empty")
    Path(dest).write_text(text)


if __name__ == "__main__":
    main()

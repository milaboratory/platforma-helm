#!/usr/bin/env python3
"""Fail when an inline CodeBuild buildspec would be rejected as too long.

CodeBuild caps an inline buildspec at 25600 characters. CloudFormation accepts
a longer one and `validate-template` reports no problem: the cap is enforced by
CodeBuild when the project resource is created, so an over-long buildspec turns
into a CREATE_FAILED half an hour into a deploy. cfn-lint does not cover it
either -- it ships no rule for AWS::CodeBuild::Project buildspecs.

The length measured here is the template's own string, before CloudFormation
substitutes !Sub placeholders. Substitution changes the final size a little in
either direction, which is what --min-headroom is for.
"""

import argparse
import sys

import yaml

LIMIT = 25600
MIN_HEADROOM = 2560


class TemplateLoader(yaml.SafeLoader):
    """SafeLoader that tolerates every CloudFormation shorthand tag.

    Enumerating the tags does not work: a template only has to add one
    (!Contains, say) for the loader to start raising ConstructorError.
    """


def _keep_structure(loader, _suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_mapping(node, deep=True)


TemplateLoader.add_multi_constructor("!", _keep_structure)


def inline_buildspecs(template):
    """Yield (resource_name, source_label, buildspec) for inline buildspecs only.

    A BuildSpec that names a file in the source tree, or points at an S3
    object, is not subject to the inline cap.
    """
    for name, resource in (template.get("Resources") or {}).items():
        if resource.get("Type") != "AWS::CodeBuild::Project":
            continue
        properties = resource.get("Properties") or {}

        sources = [("Source", properties.get("Source"))]
        for index, secondary in enumerate(properties.get("SecondarySources") or []):
            sources.append((f"SecondarySources[{index}]", secondary))

        for label, source in sources:
            if not isinstance(source, dict):
                continue
            buildspec = source.get("BuildSpec")
            if not isinstance(buildspec, str):
                continue
            if "\n" not in buildspec:
                continue
            yield name, label, buildspec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("templates", nargs="+")
    parser.add_argument("--limit", type=int, default=LIMIT)
    parser.add_argument(
        "--min-headroom",
        type=int,
        default=MIN_HEADROOM,
        help="warn when a buildspec is under the limit by less than this",
    )
    args = parser.parse_args()

    failed = False
    checked = 0

    for path in args.templates:
        with open(path) as handle:
            template = yaml.load(handle, Loader=TemplateLoader)

        for name, label, buildspec in inline_buildspecs(template):
            checked += 1
            size = len(buildspec)
            headroom = args.limit - size

            if headroom < 0:
                failed = True
                print(
                    f"::error file={path}::{name}.{label}.BuildSpec is "
                    f"{size} characters, {-headroom} over CodeBuild's "
                    f"{args.limit}-character inline limit. The project will "
                    f"fail to create. Move part of the buildspec out of the "
                    f"template or shorten it."
                )
            elif headroom < args.min_headroom:
                print(
                    f"::warning file={path}::{name}.{label}.BuildSpec is "
                    f"{size} characters, only {headroom} under the "
                    f"{args.limit}-character limit."
                )
            else:
                print(f"ok  {name}.{label}.BuildSpec  {size}/{args.limit}")

    if not checked:
        print(
            "::error::no inline CodeBuild buildspec found in "
            f"{', '.join(args.templates)} -- this check inspected nothing, "
            "which is not the same as passing",
            file=sys.stderr,
        )
        return 1

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

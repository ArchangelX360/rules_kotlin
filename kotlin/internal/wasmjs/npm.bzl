# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""npm packages of the Kotlin/WasmJs rules."""

def npm_package_entries(npm_package_attr):
    """Converts an npm package attribute into the entries of `KtWasmJsInfo.npm_packages`.

    Args:
        npm_package_attr: dict of bare import specifier to npm package files target.

    Returns:
        list of struct(specifier, label, files).
    """
    return [
        struct(
            specifier = specifier,
            label = target.label,
            files = target[DefaultInfo].files,
        )
        for specifier, target in npm_package_attr.items()
    ]

def merged_npm_packages(entries, owner):
    """Merges npm package entries into a dict keyed by specifier.

    The npm packages of a linked binary live in a single flat `/node_modules/`, so a specifier
    that two different targets provide fails.

    Args:
        entries: list of struct(specifier, label, files).
        owner: the label to report in the failure.

    Returns:
        dict of specifier to struct(specifier, label, files).
    """
    merged = {}
    for entry in entries:
        existing = merged.get(entry.specifier)
        if existing != None and existing.label != entry.label:
            fail("%s requires the npm package '%s' from conflicting targets: %s and %s" % (
                owner,
                entry.specifier,
                existing.label,
                entry.label,
            ))
        merged[entry.specifier] = entry
    return merged

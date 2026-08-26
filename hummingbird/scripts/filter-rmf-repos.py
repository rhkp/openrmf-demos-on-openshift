#!/usr/bin/env python3
"""Drop demonstrations/rmf_demos from rmf.repos (we clone that ourselves,
pinned to a specific jazzy commit, instead of the `main` ref rmf.repos
points at) and pin every remaining entry's floating `main`/`master` version
to a specific commit SHA. Upstream's rmf.repos itself only ever points at
floating branches (confirmed via raw.githubusercontent.com/open-rmf/rmf/main/rmf.repos
— every entry says `version: main` or `master`, never a tag/SHA), so without
this our build isn't reproducible: a future rebuild could silently pull
different, possibly incompatible commits for any of the ~17 packages here.
PINS below were captured via `git ls-remote` shortly after a confirmed-green
build on the bootc lineage — update them deliberately when intentionally
moving to newer upstream commits, not as a side effect of an unrelated
rebuild.
"""
import sys
import yaml

PINS = {
    "rmf/ament_cmake_catch2": "cc92786410161958d4252e0c611c2db4701655cc",
    "rmf/rmf_api_msgs": "f61c13048a2b00063c22cf955f4b279053eccba2",
    "rmf/rmf_battery": "cbd434039806f9d2cc74191a971969a715d1bb4f",
    "rmf/rmf_building_map_msgs": "0a49bd88ae5d1a2ec8f332a1a1c1e5807b9e16d6",
    "rmf/rmf_internal_msgs": "3d4df023bacaf7a091564e98f4aff0776f72a612",
    "rmf/rmf_ros2": "9fb15ac02db25773ab12dcaf423bec8114d842e1",
    "rmf/rmf_simulation": "ec6add4a842a5051a070fafb146208e7f2aa9742",
    "rmf/rmf_task": "3943e852dc44414bdb38c57c10da6c8e29618c06",
    "rmf/rmf_traffic": "39f09e7971c8e666e12c8e9b12199014f631c0bb",
    "rmf/rmf_traffic_editor": "922a66315fb374a8c4640a4f25ad447c4c58b218",
    "rmf/rmf_utils": "54cc7f6842b88b72bd125d34a8000833dd2b8a38",
    "rmf/rmf_visualization": "6c06184c3ec33441b2f94d356c2d43df4233b74a",
    "rmf/rmf_visualization_msgs": "91ce3fdd1449108d551917f541345db27fa7eac0",
    "thirdparty/menge_vendor": "9ac199bf09142be4030ce021a5b9955247717f83",
    "thirdparty/nlohmann_json_schema_validator_vendor": "43358d96f0a458f798d2d347d18ef7177042d304",
    "thirdparty/pybind11_json_vendor": "cba8192a27a3424ba093079352b3a16187824732",
}

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    d = yaml.safe_load(f)
d["repositories"].pop("demonstrations/rmf_demos", None)
missing = set(d["repositories"]) - set(PINS)
extra = set(PINS) - set(d["repositories"])
if missing or extra:
    sys.exit(
        f"rmf.repos changed shape since PINS was captured — "
        f"missing pins: {missing or None}, stale pins: {extra or None}. "
        f"Re-run `git ls-remote` for any new/changed repos and update PINS."
    )
for name, sha in PINS.items():
    d["repositories"][name]["version"] = sha
with open(dst, "w") as f:
    yaml.safe_dump(d, f)

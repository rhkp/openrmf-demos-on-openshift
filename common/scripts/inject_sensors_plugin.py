#!/usr/bin/env python3
"""Modify a gz-sim world file for DiffDrive-based Nav2 navigation.

1. Inject gz::sim::systems::Sensors plugin (required for gpu_lidar)
2. Remove liblift.so plugin (crashes with DiffDrive due to ECS incompatibility)
"""
import re
import sys

world_file = sys.argv[1]

with open(world_file) as f:
    content = f.read()

# Remove any previously injected Sensors plugins (idempotent)
content = re.sub(
    r'\s*<plugin\s+filename="libgz-sim-sensors-system\.so"[^>]*>.*?</plugin>',
    '', content, flags=re.DOTALL
)

sensors_block = """
    <plugin filename="libgz-sim-sensors-system.so" name="gz::sim::systems::Sensors">
      <render_engine>ogre2</render_engine>
    </plugin>"""

# Insert after SceneBroadcaster's closing </plugin>
pattern = r'(name="gz::sim::systems::SceneBroadcaster">\s*</plugin>)'
if re.search(pattern, content):
    content = re.sub(pattern, r'\1' + sensors_block, content)
else:
    content = content.replace(
        '<plugin filename="libdoor.so"',
        sensors_block + '\n    <plugin filename="libdoor.so"'
    )

# Remove lift plugin — crashes with DiffDrive (SIGSEGV in std::_Rb_tree_increment
# during UpdateSystems when DiffDrive joints are present in the ECS)
content = re.sub(
    r'\s*<plugin\s+filename="liblift\.so"[^>]*>.*?</plugin>',
    '', content, flags=re.DOTALL
)

robot2_pattern = r'(<include>\s*<name>tinyRobot2</name>\s*<uri>)model://TinyRobot(</uri>)'
content = re.sub(robot2_pattern, r'\1model://TinyRobot2\2', content, flags=re.DOTALL)

with open(world_file, 'w') as f:
    f.write(content)

print(f'Injected Sensors plugin, removed lift plugin, set robot2 model from {world_file}')

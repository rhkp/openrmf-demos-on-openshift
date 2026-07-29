#!/usr/bin/env python3
"""Inject gz::sim::systems::Sensors plugin into a gz-sim world file."""
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

with open(world_file, 'w') as f:
    f.write(content)

print(f'Injected Sensors plugin into {world_file}')

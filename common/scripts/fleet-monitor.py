#!/usr/bin/env python3
"""Fleet state monitor — prints robot positions every 10 seconds."""

import time

import rclpy
from rclpy.node import Node
from rmf_fleet_msgs.msg import FleetState


class Monitor(Node):
    def __init__(self):
        super().__init__("fleet_monitor_cli")
        self.sub = self.create_subscription(FleetState, "/fleet_states", self.cb, 10)
        self.last_print = 0.0

    def cb(self, msg):
        now = time.time()
        if now - self.last_print < 10:
            return
        self.last_print = now
        t_str = time.strftime("%H:%M:%S")
        print(f"\n[{t_str}] Fleet: {msg.name}")
        for r in msg.robots:
            print(
                f"  - {r.name:12} | X: {r.location.x:6.2f} | "
                f"Y: {r.location.y:6.2f} | Yaw: {r.location.yaw:5.2f} | "
                f"Batt: {r.battery_percent:4.1f}%"
            )


def main():
    rclpy.init()
    node = Monitor()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Aggregates per-robot /robot_state messages from slotcar Gazebo plugins
into /fleet_states for all downstream consumers.

In the multi-pod architecture, the fleet adapter (robot pod) cannot
communicate with the slotcar plugin (sim pod) via in-process callbacks,
so it never publishes fleet_states. This aggregator bridges the gap by
running on the sim pod alongside the slotcar plugins.
"""

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSDurabilityPolicy, QoSReliabilityPolicy

from rmf_fleet_msgs.msg import RobotState, FleetState


class FleetStateAggregator(Node):
    def __init__(self):
        super().__init__('fleet_state_aggregator')

        self.declare_parameter('fleet_name', 'tinyRobot')
        self.declare_parameter('publish_rate', 2.0)
        self.fleet_name = self.get_parameter('fleet_name').value
        publish_rate = self.get_parameter('publish_rate').value

        self.robots = {}

        self.create_subscription(
            RobotState, '/robot_state', self._robot_state_cb, 10)

        fleet_qos = QoSProfile(
            depth=10,
            reliability=QoSReliabilityPolicy.RELIABLE,
            durability=QoSDurabilityPolicy.TRANSIENT_LOCAL
        )
        self.fleet_pub = self.create_publisher(
            FleetState, '/fleet_states', fleet_qos)

        self.create_timer(1.0 / publish_rate, self._publish)

        self.get_logger().info(
            f'Fleet state aggregator started for fleet [{self.fleet_name}] '
            f'at {publish_rate} Hz')

    def _robot_state_cb(self, msg):
        self.robots[msg.name] = msg

    def _publish(self):
        if not self.robots:
            return
        fs = FleetState()
        fs.name = self.fleet_name
        fs.robots = list(self.robots.values())
        self.fleet_pub.publish(fs)


def main():
    rclpy.init()
    node = FleetStateAggregator()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

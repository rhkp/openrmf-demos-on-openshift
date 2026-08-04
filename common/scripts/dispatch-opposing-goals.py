#!/usr/bin/env python3
"""
Dispatch opposing NavigateToPose goals for two-robot collision avoidance demo.

Reads robot spawn positions from the upstream RMF fleet config, then sends
each robot to the other's start position via Nav2 NavigateToPose action.
"""

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
import math
import yaml
import os
import subprocess

from nav2_msgs.action import NavigateToPose
from action_msgs.msg import GoalStatus


class OpposingGoalDispatcher(Node):
    def __init__(self):
        super().__init__('opposing_goal_dispatcher')

        self.declare_parameter('robot_0', 'tinyRobot_0')
        self.declare_parameter('robot_1', 'tinyRobot_1')

        self.robot_0 = self.get_parameter('robot_0').value
        self.robot_1 = self.get_parameter('robot_1').value

        self.spawn_positions = self._load_spawn_positions()

        self.client_0 = ActionClient(
            self, NavigateToPose,
            f'/{self.robot_0}/navigate_to_pose'
        )
        self.client_1 = ActionClient(
            self, NavigateToPose,
            f'/{self.robot_1}/navigate_to_pose'
        )

        self.goals_sent = 0
        self.goals_complete = 0

        self.get_logger().info(
            f"Opposing goal dispatcher: {self.robot_0} <-> {self.robot_1}"
        )
        self.get_logger().info(f"Spawn positions: {self.spawn_positions}")

        self.create_timer(1.0, self._try_dispatch)

    def _load_spawn_positions(self):
        """Load robot spawn positions from upstream RMF fleet config."""
        try:
            result = subprocess.run(
                ['ros2', 'pkg', 'prefix', 'rmf_demos'],
                capture_output=True, text=True, check=True
            )
            pkg_prefix = result.stdout.strip()
            config_path = os.path.join(
                pkg_prefix, 'share', 'rmf_demos', 'config',
                'airport_terminal', 'tinyRobot_config.yaml'
            )

            with open(config_path) as f:
                config = yaml.safe_load(f)

            robots = config.get('rmf_fleet', {}).get('robots', {})
            positions = {}
            for name, robot_cfg in robots.items():
                starts = robot_cfg.get('starts', [])
                if starts:
                    start = starts[0]
                    positions[name] = {
                        'x': float(start.get('x', 0.0)),
                        'y': float(start.get('y', 0.0)),
                        'yaw': float(start.get('yaw', 0.0)),
                    }

            if positions:
                self.get_logger().info(f"Loaded spawn positions from fleet config: {positions}")
                return positions

        except Exception as e:
            self.get_logger().warn(f"Could not load fleet config: {e}")

        self.get_logger().info("Using default spawn positions")
        return {
            'tinyRobot_0': {'x': 5.35, 'y': -4.98, 'yaw': 0.0},
            'tinyRobot_1': {'x': 20.63, 'y': -3.99, 'yaw': math.pi},
        }

    def _try_dispatch(self):
        if self.goals_sent > 0:
            return

        r0_ready = self.client_0.wait_for_server(timeout_sec=1.0)
        r1_ready = self.client_1.wait_for_server(timeout_sec=1.0)

        if not r0_ready or not r1_ready:
            self.get_logger().info(
                f"Waiting for Nav2 action servers... "
                f"{self.robot_0}={'ready' if r0_ready else 'waiting'}, "
                f"{self.robot_1}={'ready' if r1_ready else 'waiting'}",
                throttle_duration_sec=10.0
            )
            return

        self.get_logger().info("Both Nav2 action servers ready, sending opposing goals!")
        self.goals_sent = 2

        # Robot 0 → Robot 1's spawn position
        r1_spawn = self.spawn_positions.get(
            self.robot_1,
            self.spawn_positions.get('tinyRobot_1', {'x': 20.63, 'y': -3.99, 'yaw': math.pi})
        )
        self._send_goal(self.client_0, self.robot_0, r1_spawn)

        # Robot 1 → Robot 0's spawn position
        r0_spawn = self.spawn_positions.get(
            self.robot_0,
            self.spawn_positions.get('tinyRobot_0', {'x': 5.35, 'y': -4.98, 'yaw': 0.0})
        )
        self._send_goal(self.client_1, self.robot_1, r0_spawn)

    def _send_goal(self, client, robot_name, target):
        goal_msg = NavigateToPose.Goal()
        goal_msg.pose.header.frame_id = f'{robot_name}/map'
        goal_msg.pose.header.stamp = self.get_clock().now().to_msg()
        goal_msg.pose.pose.position.x = target['x']
        goal_msg.pose.pose.position.y = target['y']
        goal_msg.pose.pose.position.z = 0.0

        yaw = target['yaw']
        goal_msg.pose.pose.orientation.z = math.sin(yaw / 2.0)
        goal_msg.pose.pose.orientation.w = math.cos(yaw / 2.0)

        self.get_logger().info(
            f"Sending {robot_name} to ({target['x']:.2f}, {target['y']:.2f})"
        )

        send_future = client.send_goal_async(
            goal_msg,
            feedback_callback=lambda fb, name=robot_name: self._feedback_cb(fb, name)
        )
        send_future.add_done_callback(
            lambda f, name=robot_name: self._goal_response_cb(f, name)
        )

    def _goal_response_cb(self, future, robot_name):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().error(f"{robot_name}: goal rejected!")
            return

        self.get_logger().info(f"{robot_name}: goal accepted")
        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(
            lambda f, name=robot_name: self._result_cb(f, name)
        )

    def _feedback_cb(self, feedback_msg, robot_name):
        remaining = feedback_msg.feedback.distance_remaining
        self.get_logger().info(
            f"{robot_name}: {remaining:.2f}m remaining",
            throttle_duration_sec=5.0
        )

    def _result_cb(self, future, robot_name):
        status = future.result().status
        if status == GoalStatus.STATUS_SUCCEEDED:
            self.get_logger().info(f"{robot_name}: reached goal!")
        else:
            self.get_logger().warn(f"{robot_name}: navigation ended with status {status}")

        self.goals_complete += 1
        if self.goals_complete >= 2:
            self.get_logger().info("Both robots finished navigation")


def main():
    rclpy.init()
    node = OpposingGoalDispatcher()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        node.get_logger().info("Shutting down opposing goal dispatcher")
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

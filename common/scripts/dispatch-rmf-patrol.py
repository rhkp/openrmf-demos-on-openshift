#!/usr/bin/env python3
"""
Dispatch opposing patrol tasks through the RMF task system.

Instead of sending Nav2 goals directly (bypassing RMF), this dispatches
patrol tasks through the RMF task API. The fleet adapter receives the tasks,
plans trajectories on the nav graph, registers them with rmf_traffic_schedule,
and negotiation handles any conflicts automatically.
"""

import json
import math
import time
import uuid
import rclpy
from rclpy.node import Node
from rmf_task_msgs.msg import ApiRequest, ApiResponse
from rmf_fleet_msgs.msg import FleetState


class RMFPatrolDispatcher(Node):
    def __init__(self):
        super().__init__('rmf_patrol_dispatcher')

        self.declare_parameter('robot_0', 'tinyRobot1')
        self.declare_parameter('robot_1', 'tinyRobot2')
        self.declare_parameter('robot_2', 'tinyRobot3')
        self.declare_parameter('robot_3', 'tinyRobot4')
        self.declare_parameter('fleet_name', 'tinyRobot')
        self.declare_parameter('robot_0_dest', 'wp_east')
        self.declare_parameter('robot_1_dest', 'wp_west')
        self.declare_parameter('robot_2_dest', 'wp_north')
        self.declare_parameter('robot_3_dest', 'wp_south')
        self.declare_parameter('wait_seconds', 30)

        self.robot_0 = self.get_parameter('robot_0').value
        self.robot_1 = self.get_parameter('robot_1').value
        self.robot_2 = self.get_parameter('robot_2').value
        self.robot_3 = self.get_parameter('robot_3').value
        self.fleet_name = self.get_parameter('fleet_name').value
        self.robot_0_dest = self.get_parameter('robot_0_dest').value
        self.robot_1_dest = self.get_parameter('robot_1_dest').value
        self.robot_2_dest = self.get_parameter('robot_2_dest').value
        self.robot_3_dest = self.get_parameter('robot_3_dest').value
        self.wait_seconds = self.get_parameter('wait_seconds').value

        self.task_pub = self.create_publisher(
            ApiRequest, 'task_api_requests', 10
        )
        self.create_subscription(
            ApiResponse, 'task_api_responses',
            self._response_cb, 10
        )
        self.create_subscription(
            FleetState, '/fleet_states',
            self._fleet_state_cb, 10
        )

        self.all_robots = [self.robot_0, self.robot_1,
                           self.robot_2, self.robot_3]
        self.robots_seen = set()
        self.fleet_ready = False
        self.dispatched = False
        self.pending_responses = {}
        self.robot_fleet_map = {}

        self.get_logger().info(
            f'RMF Patrol Dispatcher (4 robots): '
            f'{self.robot_0}→{self.robot_0_dest}, '
            f'{self.robot_1}→{self.robot_1_dest}, '
            f'{self.robot_2}→{self.robot_2_dest}, '
            f'{self.robot_3}→{self.robot_3_dest}'
        )

        self.create_timer(2.0, self._check_and_dispatch)

    def _fleet_state_cb(self, msg):
        for robot in msg.robots:
            if robot.name in self.all_robots and robot.name not in self.robots_seen:
                self.get_logger().info(f'Discovered robot: {robot.name} (fleet: {msg.name})')
                self.robot_fleet_map[robot.name] = msg.name
            self.robots_seen.add(robot.name)
        if (all(r in self.robots_seen for r in self.all_robots)
                and not self.fleet_ready):
            self.get_logger().info(
                f'Fleet ready with robots: {sorted(self.robots_seen)}'
            )
            self.fleet_ready = True

    def _check_and_dispatch(self):
        if self.dispatched:
            return

        if not self.fleet_ready:
            self.get_logger().info(
                'Waiting for fleet to register...',
                throttle_duration_sec=10.0
            )
            return

        self.get_logger().info('Fleet registered, dispatching cross patrols')
        self.dispatched = True

        self._dispatch_patrol(self.robot_0, self.robot_0_dest)
        self._dispatch_patrol(self.robot_1, self.robot_1_dest)
        self._dispatch_patrol(self.robot_2, self.robot_2_dest)
        self._dispatch_patrol(self.robot_3, self.robot_3_dest)

    def _dispatch_patrol(self, robot_name, destination, unix_millis=None):
        request_id = str(uuid.uuid4())

        if unix_millis is None:
            unix_millis = int(self.get_clock().now().nanoseconds / 1e6)

        task_request = {
            'category': 'patrol',
            'description': {
                'places': [destination],
                'rounds': 1,
            },
        }

        payload = {
            'type': 'robot_task_request',
            'robot': robot_name,
            'fleet': self.robot_fleet_map.get(robot_name, self.fleet_name),
            'request': task_request,
            'unix_millis_earliest_start_time': unix_millis,
            'priority': {'type': 'binary', 'value': 0},
        }

        msg = ApiRequest()
        msg.request_id = request_id
        msg.json_msg = json.dumps(payload)

        self.task_pub.publish(msg)
        self.pending_responses[request_id] = robot_name

        self.get_logger().info(
            f'Dispatched patrol: {robot_name} → {destination} '
            f'(request_id={request_id[:8]}...)'
        )

    def _response_cb(self, msg):
        if msg.request_id not in self.pending_responses:
            return

        robot = self.pending_responses.pop(msg.request_id)
        try:
            response = json.loads(msg.json_msg)
            success = response.get('success', False)
            if success:
                self.get_logger().info(
                    f'{robot}: patrol task accepted by RMF'
                )
            else:
                errors = response.get('errors', [])
                self.get_logger().warn(
                    f'{robot}: patrol task rejected: {errors}'
                )
        except json.JSONDecodeError:
            self.get_logger().warn(
                f'{robot}: invalid response: {msg.json_msg}'
            )


def main():
    rclpy.init()
    node = RMFPatrolDispatcher()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        node.get_logger().info('Shutting down patrol dispatcher')
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

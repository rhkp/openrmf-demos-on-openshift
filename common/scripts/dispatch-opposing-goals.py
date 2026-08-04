#!/usr/bin/env python3
"""
Dispatch opposing NavigateToPose goals for two-robot collision avoidance demo.

Each robot's SLAM map starts at (0,0) facing forward. We send each robot a
goal straight ahead in its own map frame. Since the robots face each other
in the world, they navigate toward each other and must handle collision.

Retries on ABORTED (goal outside SLAM map bounds) to handle map growth.
"""

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
import math

from nav2_msgs.action import NavigateToPose
from action_msgs.msg import GoalStatus


class OpposingGoalDispatcher(Node):
    def __init__(self):
        super().__init__('opposing_goal_dispatcher')

        self.declare_parameter('robot_0', 'tinyRobot_0')
        self.declare_parameter('robot_1', 'tinyRobot_1')
        self.declare_parameter('goal_distance', 3.0)
        self.declare_parameter('max_retries', 10)
        self.declare_parameter('retry_delay', 10.0)

        self.robot_0 = self.get_parameter('robot_0').value
        self.robot_1 = self.get_parameter('robot_1').value
        self.goal_distance = self.get_parameter('goal_distance').value
        self.max_retries = self.get_parameter('max_retries').value
        self.retry_delay = self.get_parameter('retry_delay').value

        self.client_0 = ActionClient(
            self, NavigateToPose,
            f'/{self.robot_0}/navigate_to_pose'
        )
        self.client_1 = ActionClient(
            self, NavigateToPose,
            f'/{self.robot_1}/navigate_to_pose'
        )

        self.dispatched = False
        self.robot_state = {
            self.robot_0: {'active': False, 'retries': 0, 'ever_accepted': False},
            self.robot_1: {'active': False, 'retries': 0, 'ever_accepted': False},
        }

        self.get_logger().info(
            f"Opposing goal dispatcher: {self.robot_0} <-> {self.robot_1}, "
            f"goal_distance={self.goal_distance}m, max_retries={self.max_retries}"
        )

        self.create_timer(1.0, self._try_dispatch)

    def _try_dispatch(self):
        if self.dispatched:
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
        self.dispatched = True

        forward_goal = {'x': self.goal_distance, 'y': 0.0, 'yaw': 0.0}
        self._send_goal(self.client_0, self.robot_0, forward_goal)
        self._send_goal(self.client_1, self.robot_1, forward_goal)

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

        attempt = self.robot_state[robot_name]['retries'] + 1
        self.get_logger().info(
            f"Sending {robot_name} to ({target['x']:.2f}, {target['y']:.2f}) "
            f"[attempt {attempt}/{self.max_retries + 1}]"
        )

        send_future = client.send_goal_async(
            goal_msg,
            feedback_callback=lambda fb, name=robot_name: self._feedback_cb(fb, name)
        )
        send_future.add_done_callback(
            lambda f, name=robot_name, c=client, t=target: self._goal_response_cb(f, name, c, t)
        )

    def _goal_response_cb(self, future, robot_name, client, target):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().error(f"{robot_name}: goal rejected!")
            self._maybe_retry(robot_name, client, target)
            return

        self.get_logger().info(f"{robot_name}: goal accepted")
        self.robot_state[robot_name]['active'] = True
        self.robot_state[robot_name]['ever_accepted'] = True
        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(
            lambda f, name=robot_name, c=client, t=target: self._result_cb(f, name, c, t)
        )

    def _feedback_cb(self, feedback_msg, robot_name):
        remaining = feedback_msg.feedback.distance_remaining
        self.get_logger().info(
            f"{robot_name}: {remaining:.2f}m remaining",
            throttle_duration_sec=5.0
        )

    def _result_cb(self, future, robot_name, client, target):
        status = future.result().status
        self.robot_state[robot_name]['active'] = False

        if status == GoalStatus.STATUS_SUCCEEDED:
            self.get_logger().info(f"{robot_name}: reached goal!")
            return

        if status == GoalStatus.STATUS_ABORTED:
            self.get_logger().warn(
                f"{robot_name}: goal ABORTED (likely outside SLAM map bounds), will retry..."
            )
            self._maybe_retry(robot_name, client, target)
            return

        self.get_logger().warn(f"{robot_name}: navigation ended with status {status}")

    def _maybe_retry(self, robot_name, client, target):
        state = self.robot_state[robot_name]
        if state['ever_accepted']:
            self.get_logger().info(
                f"{robot_name}: goal was previously accepted, not retrying "
                f"(yield controller handles resumption)"
            )
            return
        if state['retries'] >= self.max_retries:
            self.get_logger().error(
                f"{robot_name}: exhausted {self.max_retries} retries, giving up"
            )
            return

        state['retries'] += 1
        self.get_logger().info(
            f"{robot_name}: retrying in {self.retry_delay:.0f}s "
            f"(attempt {state['retries'] + 1}/{self.max_retries + 1})"
        )

        def one_shot_retry():
            timer.cancel()
            self.destroy_timer(timer)
            self._send_goal(client, robot_name, target)

        timer = self.create_timer(self.retry_delay, one_shot_retry)


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

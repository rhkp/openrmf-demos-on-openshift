#!/usr/bin/env python3
"""
Priority-based yield controller for two-robot head-on collision avoidance.

Monitors both robots' positions and headings. When a head-on scenario is
detected, the lower-priority robot yields by backing up via Nav2's BackUp
behavior action, waiting for the priority robot to pass, then resuming
its original navigation goal.
"""

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
import math
import threading
from enum import Enum

from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import NavigateToPose, BackUp, Wait
from action_msgs.msg import GoalStatus


class YieldState(Enum):
    MONITORING = 0
    CANCELING = 1
    BACKING_UP = 2
    WAITING = 3
    RESUMING = 4


class RobotYieldController(Node):
    def __init__(self):
        super().__init__('robot_yield_controller')

        self.declare_parameter('priority_robot', 'tinyRobot_0')
        self.declare_parameter('yielding_robot', 'tinyRobot_1')
        self.declare_parameter('detection_distance', 3.0)
        self.declare_parameter('heading_tolerance', 0.6)
        self.declare_parameter('backup_distance', 0.5)
        self.declare_parameter('wait_duration', 5.0)
        self.declare_parameter('resume_distance', 2.0)
        self.declare_parameter('check_frequency', 5.0)

        self.priority_robot = self.get_parameter('priority_robot').value
        self.yielding_robot = self.get_parameter('yielding_robot').value
        self.detection_distance = self.get_parameter('detection_distance').value
        self.heading_tolerance = self.get_parameter('heading_tolerance').value
        self.backup_distance = self.get_parameter('backup_distance').value
        self.wait_duration = self.get_parameter('wait_duration').value
        self.resume_distance = self.get_parameter('resume_distance').value
        check_freq = self.get_parameter('check_frequency').value

        self.declare_parameter('yielding_goal_x', 0.0)
        self.declare_parameter('yielding_goal_y', 0.0)
        self.declare_parameter('yielding_goal_yaw', 0.0)
        self.saved_goal_x = self.get_parameter('yielding_goal_x').value
        self.saved_goal_y = self.get_parameter('yielding_goal_y').value
        self.saved_goal_yaw = self.get_parameter('yielding_goal_yaw').value

        self.state = YieldState.MONITORING
        self.state_lock = threading.Lock()

        self.priority_pose = None
        self.yielding_pose = None

        self.create_subscription(
            PoseStamped,
            f'/{self.priority_robot}/world_pose',
            self._priority_pose_cb, 10
        )
        self.create_subscription(
            PoseStamped,
            f'/{self.yielding_robot}/world_pose',
            self._yielding_pose_cb, 10
        )

        self.nav_client = ActionClient(
            self, NavigateToPose,
            f'/{self.yielding_robot}/navigate_to_pose'
        )
        self.backup_client = ActionClient(
            self, BackUp,
            f'/{self.yielding_robot}/backup'
        )
        self.wait_client = ActionClient(
            self, Wait,
            f'/{self.yielding_robot}/wait'
        )

        self.yielding_goal_handle = None

        self.create_timer(1.0 / check_freq, self._check_loop)

        self.get_logger().info(
            f"Yield controller started: priority={self.priority_robot}, "
            f"yielding={self.yielding_robot}, detection={self.detection_distance}m"
        )

    def _priority_pose_cb(self, msg):
        self.priority_pose = msg

    def _yielding_pose_cb(self, msg):
        self.yielding_pose = msg

    def _extract_pose(self, pose_stamped):
        x = pose_stamped.pose.position.x
        y = pose_stamped.pose.position.y
        oz = pose_stamped.pose.orientation.z
        ow = pose_stamped.pose.orientation.w
        yaw = 2.0 * math.atan2(oz, ow)
        return x, y, yaw

    def _normalize_angle(self, angle):
        while angle > math.pi:
            angle -= 2.0 * math.pi
        while angle < -math.pi:
            angle += 2.0 * math.pi
        return angle

    def _is_head_on(self):
        if self.priority_pose is None or self.yielding_pose is None:
            return False

        px, py, p_yaw = self._extract_pose(self.priority_pose)
        yx, yy, y_yaw = self._extract_pose(self.yielding_pose)

        dx = yx - px
        dy = yy - py
        distance = math.sqrt(dx * dx + dy * dy)

        if distance > self.detection_distance or distance < 0.3:
            return False

        angle_p_to_y = math.atan2(dy, dx)
        angle_y_to_p = math.atan2(-dy, -dx)

        heading_diff_p = abs(self._normalize_angle(p_yaw - angle_p_to_y))
        heading_diff_y = abs(self._normalize_angle(y_yaw - angle_y_to_p))

        return (heading_diff_p < self.heading_tolerance and
                heading_diff_y < self.heading_tolerance)

    def _get_distance(self):
        if self.priority_pose is None or self.yielding_pose is None:
            return float('inf')
        px, py, _ = self._extract_pose(self.priority_pose)
        yx, yy, _ = self._extract_pose(self.yielding_pose)
        dx = yx - px
        dy = yy - py
        return math.sqrt(dx * dx + dy * dy)

    def _check_loop(self):
        with self.state_lock:
            if self.state == YieldState.MONITORING:
                if self._is_head_on():
                    self.get_logger().info(
                        f"Head-on detected at {self._get_distance():.2f}m! "
                        f"{self.yielding_robot} yielding..."
                    )
                    self.state = YieldState.CANCELING
                    self._cancel_yielding_goal()

            elif self.state == YieldState.WAITING:
                dist = self._get_distance()
                if dist > self.resume_distance and not self._is_head_on():
                    self.get_logger().info(
                        f"Priority robot passed (distance={dist:.2f}m). Resuming..."
                    )
                    self.state = YieldState.RESUMING
                    self._resume_goal()

    def _cancel_yielding_goal(self):
        self.get_logger().info(f"Canceling {self.yielding_robot} navigation goal")

        if not self.nav_client.wait_for_server(timeout_sec=2.0):
            self.get_logger().warn("Nav2 action server not available, skipping to backup")
            self._start_backup()
            return

        # Send a dummy goal to preempt any active NavigateToPose, then immediately
        # cancel it. Position doesn't matter since we cancel within milliseconds.
        preempt_goal = NavigateToPose.Goal()
        preempt_goal.pose.header.frame_id = f'{self.yielding_robot}/map'
        preempt_goal.pose.header.stamp = self.get_clock().now().to_msg()
        preempt_goal.pose.pose.position.x = 0.0
        preempt_goal.pose.pose.position.y = 0.0
        preempt_goal.pose.pose.orientation.w = 1.0

        send_future = self.nav_client.send_goal_async(preempt_goal)
        send_future.add_done_callback(self._on_preempt_accepted)

    def _on_preempt_accepted(self, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn("Preempt goal rejected, proceeding to backup")
            self._start_backup()
            return

        cancel_future = goal_handle.cancel_goal_async()
        cancel_future.add_done_callback(self._on_cancel_done)

    def _on_cancel_done(self, future):
        try:
            future.result()
            self.get_logger().info("Navigation preempted and canceled, starting backup")
        except Exception as e:
            self.get_logger().warn(f"Cancel failed: {e}, proceeding to backup anyway")

        self._start_backup()

    def _start_backup(self):
        if not self.backup_client.wait_for_server(timeout_sec=5.0):
            self.get_logger().warn("BackUp action server not available, going to wait state")
            with self.state_lock:
                self.state = YieldState.WAITING
            return

        goal = BackUp.Goal()
        goal.target.x = -self.backup_distance
        goal.speed = 0.15
        goal.time_allowance.sec = 10

        self.get_logger().info(f"Backing up {self.backup_distance}m...")
        send_future = self.backup_client.send_goal_async(goal)
        send_future.add_done_callback(self._on_backup_accepted)

        with self.state_lock:
            self.state = YieldState.BACKING_UP

    def _on_backup_accepted(self, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn("BackUp goal rejected, going to wait state")
            with self.state_lock:
                self.state = YieldState.WAITING
            return

        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(self._on_backup_done)

    def _on_backup_done(self, future):
        self.get_logger().info("Backup complete, waiting for priority robot to pass...")
        with self.state_lock:
            self.state = YieldState.WAITING

    def _resume_goal(self):
        if not self.nav_client.wait_for_server(timeout_sec=5.0):
            self.get_logger().error("Nav2 action server not available for resume")
            with self.state_lock:
                self.state = YieldState.MONITORING
            return

        goal_msg = NavigateToPose.Goal()
        goal_msg.pose.header.frame_id = f'{self.yielding_robot}/map'
        goal_msg.pose.header.stamp = self.get_clock().now().to_msg()
        goal_msg.pose.pose.position.x = self.saved_goal_x
        goal_msg.pose.pose.position.y = self.saved_goal_y
        goal_msg.pose.pose.position.z = 0.0

        yaw = self.saved_goal_yaw
        goal_msg.pose.pose.orientation.z = math.sin(yaw / 2.0)
        goal_msg.pose.pose.orientation.w = math.cos(yaw / 2.0)

        self.get_logger().info(
            f"Resuming {self.yielding_robot} goal: "
            f"({self.saved_goal_x}, {self.saved_goal_y})"
        )

        send_future = self.nav_client.send_goal_async(goal_msg)
        send_future.add_done_callback(self._on_resume_accepted)

    def _on_resume_accepted(self, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn("Resume goal rejected")
        else:
            self.yielding_goal_handle = goal_handle
            self.get_logger().info("Navigation resumed")

        with self.state_lock:
            self.state = YieldState.MONITORING


def main():
    rclpy.init()
    node = RobotYieldController()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        node.get_logger().info("Shutting down yield controller")
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

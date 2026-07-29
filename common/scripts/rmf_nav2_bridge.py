#!/usr/bin/env python3
"""
RMF-Nav2 Integration Bridge

Bridges RMF fleet adapter with Nav2 navigation stack to enable sensor-based
autonomous navigation while maintaining RMF fleet coordination capabilities.

This bridge:
- Receives navigation goals from RMF fleet adapter
- Converts RMF waypoints to Nav2 navigation goals
- Monitors Nav2 execution status
- Reports progress back to RMF fleet adapter
- Handles obstacle avoidance via Nav2 local planning
"""

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
import math
import threading
from typing import Optional

# RMF messages
from rmf_fleet_msgs.msg import RobotMode, ModeRequest

# Nav2 action messages
from nav2_msgs.action import NavigateToPose
from geometry_msgs.msg import PoseStamped, Twist
from action_msgs.msg import GoalStatus


class RMFNav2Bridge(Node):
    def __init__(self):
        super().__init__('rmf_nav2_bridge')

        # Robot configuration
        self.declare_parameter('robot_name', 'tinyRobot1')
        self.declare_parameter('fleet_name', 'tinyRobot')
        self.robot_name = self.get_parameter('robot_name').value
        self.fleet_name = self.get_parameter('fleet_name').value

        # RMF waypoint mapping (office environment)
        self.waypoints = {
            'coe': {'x': 5.35, 'y': -4.98, 'yaw': 0.0},
            'lounge': {'x': 20.63, 'y': -3.99, 'yaw': 0.0},
            'tinyRobot1_charger': {'x': 10.43, 'y': -5.58, 'yaw': 0.0},
            'tinyRobot2_charger': {'x': 20.42, 'y': -5.31, 'yaw': 0.0},
        }

        # Navigation state
        self.current_goal: Optional[str] = None
        self.nav2_goal_handle = None
        self.navigation_active = False
        self.robot_position = {'x': 0.0, 'y': 0.0, 'yaw': 0.0}
        self.goal_lock = threading.Lock()

        self.mode_request_sub = self.create_subscription(
            ModeRequest,
            f'/{self.fleet_name}/{self.robot_name}/mode_request',
            self.mode_request_callback,
            10
        )

        # Nav2 Action Client
        self.nav2_client = ActionClient(
            self,
            NavigateToPose,
            f'/{self.robot_name}/navigate_to_pose'
        )

        # Command velocity publisher (for direct control if needed)
        self.cmd_vel_pub = self.create_publisher(
            Twist,
            f'/{self.robot_name}/cmd_vel',
            10
        )

        self.get_logger().info(f"RMF-Nav2 Bridge started for {self.fleet_name}/{self.robot_name}")

    def mode_request_callback(self, msg: ModeRequest):
        """Handle mode requests from RMF fleet adapter."""
        self.get_logger().info(f"Received mode request: {msg.mode.mode}")

        if msg.mode.mode == RobotMode.MODE_MOVING:
            # Extract destination from mode request
            if hasattr(msg.mode, 'mode_request_id'):
                destination = msg.mode.mode_request_id
                self.navigate_to_waypoint(destination)

        elif msg.mode.mode == RobotMode.MODE_PAUSED:
            self.cancel_navigation()

        elif msg.mode.mode == RobotMode.MODE_IDLE:
            self.cancel_navigation()

    def navigate_to_waypoint(self, waypoint_name: str):
        """Convert RMF waypoint to Nav2 navigation goal."""
        if waypoint_name not in self.waypoints:
            self.get_logger().error(f"Unknown waypoint: {waypoint_name}")
            return

        with self.goal_lock:
            # Cancel existing navigation
            if self.navigation_active:
                self.cancel_navigation()

            self.current_goal = waypoint_name
            waypoint = self.waypoints[waypoint_name]

            # Wait for Nav2 action server
            if not self.nav2_client.wait_for_server(timeout_sec=5.0):
                self.get_logger().error("Nav2 action server not available")
                return

            # Create Nav2 goal
            goal_msg = NavigateToPose.Goal()
            goal_msg.pose.header.frame_id = 'map'
            goal_msg.pose.header.stamp = self.get_clock().now().to_msg()

            goal_msg.pose.pose.position.x = waypoint['x']
            goal_msg.pose.pose.position.y = waypoint['y']
            goal_msg.pose.pose.position.z = 0.0

            # Convert yaw to quaternion
            yaw = waypoint['yaw']
            goal_msg.pose.pose.orientation.x = 0.0
            goal_msg.pose.pose.orientation.y = 0.0
            goal_msg.pose.pose.orientation.z = math.sin(yaw / 2.0)
            goal_msg.pose.pose.orientation.w = math.cos(yaw / 2.0)

            self.get_logger().info(
                f"Sending Nav2 goal: {waypoint_name} -> ({waypoint['x']}, {waypoint['y']})"
            )

            # Send goal to Nav2
            send_goal_future = self.nav2_client.send_goal_async(
                goal_msg,
                feedback_callback=self.nav2_feedback_callback
            )
            send_goal_future.add_done_callback(self.nav2_goal_response_callback)

            self.navigation_active = True

    def nav2_goal_response_callback(self, future):
        """Handle Nav2 goal acceptance."""
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().error("Nav2 goal rejected")
            self.navigation_active = False
            return

        self.nav2_goal_handle = goal_handle
        self.get_logger().info("Nav2 goal accepted, waiting for result...")

        get_result_future = goal_handle.get_result_async()
        get_result_future.add_done_callback(self.nav2_result_callback)

    def nav2_feedback_callback(self, feedback_msg):
        """Handle Nav2 navigation feedback."""
        # Update robot position from Nav2 feedback
        pose = feedback_msg.feedback.current_pose.pose
        self.robot_position = {
            'x': pose.position.x,
            'y': pose.position.y,
            'yaw': 2.0 * math.atan2(pose.orientation.z, pose.orientation.w)
        }

        # Log progress periodically
        distance_remaining = feedback_msg.feedback.distance_remaining
        self.get_logger().info(
            f"Nav2 progress: {distance_remaining:.2f}m remaining to {self.current_goal}",
            throttle_duration_sec=2.0
        )

    def nav2_result_callback(self, future):
        """Handle Nav2 navigation completion."""
        result = future.result().result
        status = future.result().status

        with self.goal_lock:
            self.navigation_active = False
            self.nav2_goal_handle = None

            if status == GoalStatus.STATUS_SUCCEEDED:
                self.get_logger().info(f"Navigation to {self.current_goal} completed successfully")
                # Update position to goal position
                if self.current_goal in self.waypoints:
                    waypoint = self.waypoints[self.current_goal]
                    self.robot_position = {
                        'x': waypoint['x'],
                        'y': waypoint['y'],
                        'yaw': waypoint['yaw']
                    }
            else:
                self.get_logger().warn(f"Navigation to {self.current_goal} failed with status: {status}")

            self.current_goal = None

    def cancel_navigation(self):
        """Cancel active Nav2 navigation."""
        with self.goal_lock:
            if self.navigation_active and self.nav2_goal_handle:
                self.get_logger().info("Canceling active navigation")
                cancel_future = self.nav2_goal_handle.cancel_goal_async()
                cancel_future.add_done_callback(self.cancel_response_callback)

            self.navigation_active = False
            self.current_goal = None

    def cancel_response_callback(self, future):
        """Handle navigation cancellation response."""
        cancel_response = future.result()
        if len(cancel_response.goals_canceling) > 0:
            self.get_logger().info("Navigation successfully canceled")
        else:
            self.get_logger().warn("Failed to cancel navigation")

    def emergency_stop(self):
        """Emergency stop - publish zero velocity."""
        stop_msg = Twist()
        self.cmd_vel_pub.publish(stop_msg)
        self.cancel_navigation()


def main():
    rclpy.init()

    bridge = RMFNav2Bridge()

    try:
        rclpy.spin(bridge)
    except KeyboardInterrupt:
        bridge.get_logger().info("Shutting down RMF-Nav2 bridge")
    finally:
        bridge.emergency_stop()
        bridge.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
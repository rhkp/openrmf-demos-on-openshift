#!/usr/bin/env python3
"""
Fleet Coordinator for Robot-as-Pod Architecture

Centralized task assignment and fleet optimization for distributed robot pods.
Replaces decentralized bidding with coordinated task orchestration.
"""

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSDurabilityPolicy, QoSReliabilityPolicy
import json
import math
import time
from typing import Dict, List, Optional, Tuple

from rmf_fleet_msgs.msg import FleetState
from rmf_task_msgs.msg import TaskSummary, TaskProfile, BidNotice, BidResponse
from std_msgs.msg import String


class Robot:
    def __init__(self, name: str, fleet_name: str):
        self.name = name
        self.fleet_name = fleet_name
        self.x = 0.0
        self.y = 0.0
        self.yaw = 0.0
        self.battery_percent = 100.0
        self.mode = 0  # 0=idle, 1=charging, 2=moving, 3=paused, etc.
        self.current_task_id = ""
        self.last_update = time.time()
        self.available = True

    def update_from_fleet_state(self, robot_state):
        """Update robot state from FleetState message"""
        self.x = robot_state.location.x
        self.y = robot_state.location.y
        self.yaw = robot_state.location.yaw
        self.battery_percent = robot_state.battery_percent
        self.mode = robot_state.mode.mode
        self.current_task_id = robot_state.task_id
        self.last_update = time.time()
        # Robot is available if idle and has sufficient battery
        self.available = (self.mode == 0 and
                         self.battery_percent > 20.0 and
                         not self.current_task_id)

    def distance_to(self, x: float, y: float) -> float:
        """Calculate Euclidean distance to target coordinates"""
        return math.sqrt((self.x - x) ** 2 + (self.y - y) ** 2)

    def is_stale(self, timeout_seconds: float = 30.0) -> bool:
        """Check if robot state is stale (no recent updates)"""
        return time.time() - self.last_update > timeout_seconds


class FleetCoordinator(Node):
    def __init__(self):
        super().__init__('fleet_coordinator')

        self.robots: Dict[str, Robot] = {}
        self.task_assignments: Dict[str, str] = {}  # task_id -> robot_name

        # Known waypoints for the office map (simplified)
        # In a real implementation, this would be read from the nav graph
        self.waypoints = {
            'coe': (5.35, -4.98),
            'lounge': (20.63, -3.99),
            'tinyRobot1_charger': (10.43, -5.58),
            'tinyRobot2_charger': (20.42, -5.31),
        }

        # QoS for fleet state (transient local for latest state)
        fleet_qos = QoSProfile(
            depth=10,
            durability=QoSDurabilityPolicy.TRANSIENT_LOCAL,
            reliability=QoSReliabilityPolicy.RELIABLE
        )

        # Subscribers
        self.fleet_state_sub = self.create_subscription(
            FleetState,
            '/fleet_states',
            self.fleet_state_callback,
            fleet_qos
        )

        self.bid_notice_sub = self.create_subscription(
            BidNotice,
            'rmf_traffic/bid_notices',
            self.bid_notice_callback,
            10
        )

        # Publishers
        self.bid_response_pub = self.create_publisher(
            BidResponse,
            'rmf_traffic/bid_responses',
            10
        )

        self.coordinator_status_pub = self.create_publisher(
            String,
            '/fleet_coordinator_status',
            10
        )

        # Status timer
        self.status_timer = self.create_timer(10.0, self.publish_status)

        self.get_logger().info("Fleet Coordinator started - monitoring robot pods")

    def fleet_state_callback(self, msg: FleetState):
        """Process fleet state updates from robot pods"""
        fleet_name = msg.name

        for robot_state in msg.robots:
            robot_key = f"{fleet_name}/{robot_state.name}"

            if robot_key not in self.robots:
                self.robots[robot_key] = Robot(robot_state.name, fleet_name)
                self.get_logger().info(f"Registered robot: {robot_key}")

            self.robots[robot_key].update_from_fleet_state(robot_state)

    def bid_notice_callback(self, msg: BidNotice):
        """Handle task assignment requests - centralized coordination (robots don't bid)"""
        task_id = msg.task_id

        self.get_logger().info(f"🎯 Fleet Coordinator received task: {task_id}")

        # Parse task to understand requirements
        task_info = self.parse_task_profile(msg.task_profile)
        if not task_info:
            self.get_logger().warn(f"Could not parse task profile for {task_id}")
            return

        # Find best robot for this task using optimization criteria
        best_robot = self.select_optimal_robot(task_info)
        if not best_robot:
            self.get_logger().warn(f"No available robot for task {task_id}")
            return

        # Directly assign task to selected robot (no bidding competition)
        self.get_logger().info(f"📋 Fleet Coordinator assigning {task_id} to {best_robot}")
        self.assign_task(task_id, best_robot, msg)

    def parse_task_profile(self, task_profile) -> Optional[Dict]:
        """Parse task profile to extract requirements"""
        try:
            # For patrol tasks, extract the first waypoint as the starting location
            if hasattr(task_profile, 'description') and task_profile.description:
                description = json.loads(task_profile.description)
                if description.get('category') == 'patrol':
                    places = description.get('description', {}).get('places', [])
                    if places:
                        return {
                            'type': 'patrol',
                            'start_location': places[0],
                            'places': places,
                            'rounds': description.get('description', {}).get('rounds', 1)
                        }

            # Fallback - assume it's a general task starting at 'coe'
            return {'type': 'general', 'start_location': 'coe'}

        except Exception as e:
            self.get_logger().error(f"Error parsing task profile: {e}")
            return None

    def select_optimal_robot(self, task_info: Dict) -> Optional[str]:
        """Select the best robot for a task based on optimization criteria"""
        available_robots = [
            (name, robot) for name, robot in self.robots.items()
            if robot.available and not robot.is_stale()
        ]

        if not available_robots:
            return None

        start_location = task_info.get('start_location', 'coe')
        start_coords = self.waypoints.get(start_location, (0, 0))

        # Scoring criteria (lower score = better)
        best_robot = None
        best_score = float('inf')

        for robot_name, robot in available_robots:
            # Distance to start location (primary factor)
            distance = robot.distance_to(start_coords[0], start_coords[1])

            # Battery level (secondary factor - prefer higher battery)
            battery_penalty = (100 - robot.battery_percent) * 0.1

            # Workload balancing (prefer robots with fewer recent tasks)
            # For now, just prefer robots that are truly idle
            idle_bonus = -10.0 if robot.mode == 0 else 0.0

            total_score = distance + battery_penalty + idle_bonus

            self.get_logger().info(
                f"Robot {robot_name}: distance={distance:.2f}, "
                f"battery={robot.battery_percent:.1f}%, score={total_score:.2f}"
            )

            if total_score < best_score:
                best_score = total_score
                best_robot = robot_name

        self.get_logger().info(f"Selected robot {best_robot} with score {best_score:.2f}")
        return best_robot

    def assign_task(self, task_id: str, robot_name: str, bid_notice: BidNotice):
        """Assign task to the selected robot via coordinated response"""
        self.task_assignments[task_id] = robot_name

        # Create authoritative bid response for the selected robot
        # This bypasses competitive bidding with a coordinator decision
        response = BidResponse()
        response.task_id = task_id
        response.robot_name = robot_name.split('/')[-1]  # Just the robot name, not fleet/robot
        response.fleet_name = robot_name.split('/')[0]   # Fleet name
        response.proposal = bid_notice.task_profile  # Echo back the task profile
        response.proposal.fleet_name = response.fleet_name

        # Set authoritative coordinator assignment (very low cost to guarantee win)
        response.proposal.estimated_finish_time = self.get_clock().now().to_msg()
        response.proposal.estimated_finish_time.sec += 300  # Estimate 5 minutes

        self.bid_response_pub.publish(response)

        self.get_logger().info(f"✅ Coordinated assignment: {task_id} → {robot_name}")
        self.get_logger().info(f"   Reason: Optimal robot selected by fleet coordinator")

    def publish_status(self):
        """Publish coordinator status for monitoring"""
        available_count = sum(1 for r in self.robots.values() if r.available and not r.is_stale())
        total_count = len([r for r in self.robots.values() if not r.is_stale()])

        status = {
            'timestamp': time.time(),
            'total_robots': total_count,
            'available_robots': available_count,
            'active_tasks': len(self.task_assignments),
            'robots': {
                name: {
                    'available': robot.available,
                    'battery': robot.battery_percent,
                    'position': [robot.x, robot.y],
                    'current_task': robot.current_task_id,
                    'stale': robot.is_stale()
                }
                for name, robot in self.robots.items()
                if not robot.is_stale()
            }
        }

        status_msg = String()
        status_msg.data = json.dumps(status, indent=2)
        self.coordinator_status_pub.publish(status_msg)


def main():
    rclpy.init()
    coordinator = FleetCoordinator()

    try:
        rclpy.spin(coordinator)
    except KeyboardInterrupt:
        pass
    finally:
        coordinator.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
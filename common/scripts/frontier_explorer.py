#!/usr/bin/env python3
"""Autonomous frontier explorer for SLAM mapping.

Reads the SLAM occupancy grid, finds frontier cells (free cells adjacent to
unknown cells), clusters them, picks the largest frontier centroid that is
far enough away, and sends a Nav2 NavigateToPose goal.  Repeats until no
reachable frontiers remain.
"""

import math
import time
from collections import deque

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
from nav_msgs.msg import OccupancyGrid, Odometry
from nav2_msgs.action import NavigateToPose
from geometry_msgs.msg import PoseStamped
from action_msgs.msg import GoalStatus

BLACKLIST_EXPIRY_SEC = 300.0
BLACKLIST_THRESHOLD = 0.5
BLACKLIST_MAX_SIZE = 50
CONSECUTIVE_FAIL_NEAREST = 2
CONSECUTIVE_FAIL_BACKTRACK = 4


class FrontierExplorer(Node):
    def __init__(self):
        super().__init__('frontier_explorer')
        self.declare_parameter('robot_name', 'tinyRobot_0')
        self.declare_parameter('min_frontier_size', 5)
        self.declare_parameter('min_goal_distance', 2.0)
        self.declare_parameter('plan_interval', 8.0)
        self.declare_parameter('goal_timeout', 120.0)

        self.robot = self.get_parameter('robot_name').value
        self.min_frontier = self.get_parameter('min_frontier_size').value
        self.min_dist = self.get_parameter('min_goal_distance').value
        self.plan_interval = self.get_parameter('plan_interval').value
        self.goal_timeout = self.get_parameter('goal_timeout').value

        self.map_data = None
        self.map_info = None
        self.robot_x = 0.0
        self.robot_y = 0.0
        self.have_odom = False
        self.navigating = False
        self.blacklist = []
        self.consecutive_fails = 0
        self.successful_goals = []

        self.map_sub = self.create_subscription(
            OccupancyGrid,
            f'/{self.robot}/map',
            self._map_cb, 10)

        self.odom_sub = self.create_subscription(
            Odometry,
            f'/{self.robot}/odom',
            self._odom_cb, 10)

        self.nav_client = ActionClient(
            self, NavigateToPose,
            f'/{self.robot}/navigate_to_pose')

        self.get_logger().info(
            f'Frontier explorer started for {self.robot}, '
            f'min_frontier={self.min_frontier}, min_dist={self.min_dist}m')

        self.timer = self.create_timer(self.plan_interval, self._plan)

    def _map_cb(self, msg):
        self.map_data = np.array(msg.data, dtype=np.int8).reshape(
            msg.info.height, msg.info.width)
        self.map_info = msg.info

    def _odom_cb(self, msg):
        self.robot_x = msg.pose.pose.position.x
        self.robot_y = msg.pose.pose.position.y
        self.have_odom = True

    def _expire_blacklist(self):
        now = time.time()
        before = len(self.blacklist)
        self.blacklist = [
            (x, y, t) for x, y, t in self.blacklist
            if now - t < BLACKLIST_EXPIRY_SEC
        ]
        expired = before - len(self.blacklist)
        if expired > 0:
            self.get_logger().info(
                f'Expired {expired} blacklist entries, {len(self.blacklist)} remain')
        if len(self.blacklist) > BLACKLIST_MAX_SIZE:
            removed = len(self.blacklist) - BLACKLIST_MAX_SIZE
            self.blacklist = self.blacklist[-BLACKLIST_MAX_SIZE:]
            self.get_logger().info(
                f'Trimmed {removed} oldest blacklist entries (cap={BLACKLIST_MAX_SIZE})')

    def _blacklist_add(self, x, y):
        self.blacklist.append((x, y, time.time()))

    def _plan(self):
        if self.map_data is None:
            self.get_logger().info('Waiting for SLAM map...')
            return
        if not self.have_odom:
            self.get_logger().info('Waiting for odom...')
            return
        if self.navigating:
            if hasattr(self, '_goal_start') and \
                    time.time() - self._goal_start > self.goal_timeout:
                self.get_logger().warn(
                    f'Goal timed out after {self.goal_timeout}s, cancelling')
                if hasattr(self, '_goal_handle') and self._goal_handle:
                    self._goal_handle.cancel_goal_async()
                self._blacklist_add(*self._goal_xy)
                self.navigating = False
            return

        self._expire_blacklist()

        if self.consecutive_fails >= CONSECUTIVE_FAIL_BACKTRACK and self.successful_goals:
            bt = self.successful_goals[-1]
            dist = math.sqrt((bt[0] - self.robot_x)**2 + (bt[1] - self.robot_y)**2)
            if dist > 0.5:
                self.get_logger().warn(
                    f'Backtracking to previous goal ({bt[0]:.1f},{bt[1]:.1f}) '
                    f'after {self.consecutive_fails} consecutive failures')
                self.successful_goals.pop()
                self.consecutive_fails = 0
                self._send_goal(bt[0], bt[1])
                return

        frontiers = self._find_frontiers()
        if not frontiers:
            self.get_logger().info('No frontiers found — map may be complete!')
            return

        candidates = []
        for frontier in frontiers:
            if len(frontier) < self.min_frontier:
                continue
            cx, cy = self._centroid(frontier)
            dist = math.sqrt((cx - self.robot_x)**2 + (cy - self.robot_y)**2)
            if dist < self.min_dist:
                continue
            if self._is_blacklisted(cx, cy):
                continue
            candidates.append((cx, cy, len(frontier), dist))

        if not candidates:
            if self.blacklist:
                self.get_logger().warn(
                    f'All frontiers blocked by {len(self.blacklist)} '
                    f'blacklist entries — clearing oldest half')
                half = max(1, len(self.blacklist) // 2)
                self.blacklist = self.blacklist[half:]
                return
            self.get_logger().info(
                f'No reachable frontier > {self.min_dist}m away '
                f'(found {len(frontiers)} total)')
            return

        if self.consecutive_fails >= CONSECUTIVE_FAIL_NEAREST:
            candidates.sort(key=lambda c: c[3])
            mode = 'nearest'
        else:
            candidates.sort(key=lambda c: c[2] / (c[3] + 1.0), reverse=True)
            mode = 'score'

        cx, cy, size, dist = candidates[0]
        self.get_logger().info(
            f'Navigating to frontier ({cx:.1f}, {cy:.1f}), '
            f'size={size}, dist={dist:.1f}m, mode={mode} '
            f'[robot@({self.robot_x:.1f},{self.robot_y:.1f}), '
            f'blacklist={len(self.blacklist)}, fails={self.consecutive_fails}]')
        self._send_goal(cx, cy)

    def _find_frontiers(self):
        h, w = self.map_data.shape
        free = self.map_data == 0
        unknown = self.map_data == -1

        frontier_mask = np.zeros((h, w), dtype=bool)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                shifted = np.roll(np.roll(unknown, dy, axis=0), dx, axis=1)
                frontier_mask |= (free & shifted)

        visited = np.zeros((h, w), dtype=bool)
        clusters = []

        ys, xs = np.where(frontier_mask)
        for y, x in zip(ys, xs):
            if visited[y, x]:
                continue
            cluster = []
            queue = deque([(y, x)])
            visited[y, x] = True
            while queue:
                cy, cx = queue.popleft()
                cluster.append((cy, cx))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx] and frontier_mask[ny, nx]:
                            visited[ny, nx] = True
                            queue.append((ny, nx))
            clusters.append(cluster)

        return clusters

    def _centroid(self, cluster):
        res = self.map_info.resolution
        ox = self.map_info.origin.position.x
        oy = self.map_info.origin.position.y
        avg_y = sum(c[0] for c in cluster) / len(cluster)
        avg_x = sum(c[1] for c in cluster) / len(cluster)
        return ox + avg_x * res, oy + avg_y * res

    def _is_blacklisted(self, x, y):
        for bx, by, _t in self.blacklist:
            if math.sqrt((x - bx)**2 + (y - by)**2) < BLACKLIST_THRESHOLD:
                return True
        return False

    def _send_goal(self, x, y):
        goal = NavigateToPose.Goal()
        goal.pose = PoseStamped()
        goal.pose.header.frame_id = f'{self.robot}/map'
        goal.pose.header.stamp = self.get_clock().now().to_msg()
        goal.pose.pose.position.x = x
        goal.pose.pose.position.y = y
        goal.pose.pose.orientation.w = 1.0

        self.navigating = True
        self.nav_client.wait_for_server()
        future = self.nav_client.send_goal_async(goal)
        future.add_done_callback(self._goal_response_cb)
        self._goal_start = time.time()
        self._goal_xy = (x, y)

    def _goal_response_cb(self, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn('Goal rejected')
            self._blacklist_add(*self._goal_xy)
            self.navigating = False
            return
        self._goal_handle = goal_handle
        self.get_logger().info('Goal accepted, navigating...')
        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(self._result_cb)

    def _result_cb(self, future):
        result = future.result()
        status = result.status
        if status == GoalStatus.STATUS_SUCCEEDED:
            self.consecutive_fails = 0
            self.successful_goals.append(self._goal_xy)
            if len(self.successful_goals) > 20:
                self.successful_goals = self.successful_goals[-20:]
            self.get_logger().info(
                f'Goal reached at ({self._goal_xy[0]:.1f},{self._goal_xy[1]:.1f})! '
                f'Robot@({self.robot_x:.1f},{self.robot_y:.1f})')
        else:
            self.consecutive_fails += 1
            self.get_logger().warn(
                f'Goal failed (status={status}), blacklisting '
                f'(consecutive_fails={self.consecutive_fails})')
            self._blacklist_add(*self._goal_xy)
        self.navigating = False


def main():
    rclpy.init()
    node = FrontierExplorer()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()

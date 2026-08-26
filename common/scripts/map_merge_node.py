#!/usr/bin/env python3
"""
Merges each robot's independent slam_toolbox map into a single occupancy
grid for visualization, using the known world->{robot}/map static
transforms (from Gazebo ground-truth spawn pose) that global_tf_publisher.py
already publishes. This is a known-transform grid stitch, not general
unknown-pose map merging (multirobot_map_merge/m-explore is excluded from
the RoboStack/conda build — see bootc/Containerfile) — visualization-only,
does not feed back into Nav2/SLAM.
"""

import math

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, QoSDurabilityPolicy, QoSReliabilityPolicy
from rclpy.time import Time
from nav_msgs.msg import OccupancyGrid
from tf2_ros import Buffer, TransformListener
from tf2_ros import LookupException, ConnectivityException, ExtrapolationException

DEFAULT_ROBOTS = ['tinyRobot1', 'tinyRobot2', 'tinyRobot3', 'tinyRobot4']
WORLD_FRAME = 'world'
MERGE_PERIOD_SEC = 3.0  # matches slam_toolbox's map_update_interval


def yaw_from_quaternion(q):
    siny_cosp = 2.0 * (q.w * q.z + q.x * q.y)
    cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(siny_cosp, cosy_cosp)


class MapMergeNode(Node):
    def __init__(self):
        super().__init__('map_merge_node')

        self.declare_parameter('robot_names', DEFAULT_ROBOTS)
        self.robots = list(self.get_parameter('robot_names').value)

        map_qos = QoSProfile(
            depth=1,
            reliability=QoSReliabilityPolicy.RELIABLE,
            durability=QoSDurabilityPolicy.TRANSIENT_LOCAL
        )

        self.maps = {}
        for robot in self.robots:
            self.create_subscription(
                OccupancyGrid, f'/{robot}/map',
                lambda msg, r=robot: self._map_cb(msg, r), map_qos)

        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)

        self.merged_pub = self.create_publisher(
            OccupancyGrid, '/merged_map', map_qos)

        self.create_timer(MERGE_PERIOD_SEC, self._merge_and_publish)

        self.get_logger().info(
            f'Map merge node started for robots: {self.robots}')

    def _map_cb(self, msg: OccupancyGrid, robot_name: str):
        self.maps[robot_name] = msg

    def _lookup_robot_map_transform(self, robot_name: str):
        try:
            return self.tf_buffer.lookup_transform(
                WORLD_FRAME, f'{robot_name}/map', Time())
        except (LookupException, ConnectivityException, ExtrapolationException):
            return None

    def _merge_and_publish(self):
        sources = []
        for robot, grid in self.maps.items():
            tf = self._lookup_robot_map_transform(robot)
            if tf is None:
                continue
            yaw = yaw_from_quaternion(tf.transform.rotation)
            sources.append({
                'grid': grid,
                'tx': tf.transform.translation.x,
                'ty': tf.transform.translation.y,
                'yaw': yaw,
            })

        if not sources:
            return

        resolution = sources[0]['grid'].info.resolution

        # Union bounds of every source map's 4 corners, transformed into world.
        min_x = min_y = math.inf
        max_x = max_y = -math.inf
        for src in sources:
            info = src['grid'].info
            cos_y, sin_y = math.cos(src['yaw']), math.sin(src['yaw'])
            for cx, cy in ((0, 0), (info.width, 0), (0, info.height),
                           (info.width, info.height)):
                # corner in the source map's own local (unrotated) frame
                lx = info.origin.position.x + cx * resolution
                ly = info.origin.position.y + cy * resolution
                wx = src['tx'] + lx * cos_y - ly * sin_y
                wy = src['ty'] + lx * sin_y + ly * cos_y
                min_x, max_x = min(min_x, wx), max(max_x, wx)
                min_y, max_y = min(min_y, wy), max(max_y, wy)

        width = max(1, int(math.ceil((max_x - min_x) / resolution)))
        height = max(1, int(math.ceil((max_y - min_y) / resolution)))

        # UNKNOWN everywhere, then fold in each source (OCCUPIED > FREE > UNKNOWN).
        merged = np.full((height, width), -1, dtype=np.int8)

        out_y, out_x = np.mgrid[0:height, 0:width]
        world_x = min_x + (out_x + 0.5) * resolution
        world_y = min_y + (out_y + 0.5) * resolution

        for src in sources:
            info = src['grid'].info
            cos_y, sin_y = math.cos(-src['yaw']), math.sin(-src['yaw'])
            # backward-map: world -> source map's local frame -> source cell index
            dx = world_x - src['tx']
            dy = world_y - src['ty']
            lx = dx * cos_y - dy * sin_y
            ly = dx * sin_y + dy * cos_y
            src_col = np.floor((lx - info.origin.position.x) / resolution).astype(np.int64)
            src_row = np.floor((ly - info.origin.position.y) / resolution).astype(np.int64)

            in_bounds = (
                (src_col >= 0) & (src_col < info.width)
                & (src_row >= 0) & (src_row < info.height)
            )
            if not np.any(in_bounds):
                continue

            src_data = np.asarray(src['grid'].data, dtype=np.int8).reshape(
                info.height, info.width)
            sampled = np.full((height, width), -1, dtype=np.int8)
            rows, cols = src_row[in_bounds], src_col[in_bounds]
            sampled[in_bounds] = src_data[rows, cols]

            occupied = sampled == 100
            free = sampled == 0
            merged[occupied] = 100
            merged[free & (merged != 100)] = 0

        out = OccupancyGrid()
        out.header.stamp = self.get_clock().now().to_msg()
        out.header.frame_id = WORLD_FRAME
        out.info.resolution = resolution
        out.info.width = width
        out.info.height = height
        out.info.origin.position.x = min_x
        out.info.origin.position.y = min_y
        out.info.origin.orientation.w = 1.0
        out.data = merged.flatten().tolist()

        self.merged_pub.publish(out)


def main():
    rclpy.init()
    node = MapMergeNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

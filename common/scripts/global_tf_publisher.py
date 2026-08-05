#!/usr/bin/env python3
"""
Publishes TF on global /tf for RViz visualization on the simulation pod.

Creates a world-aligned TF tree:
  world → {robot}/map  (static, from Gazebo world poses)
  {robot}/map → {robot}/odom  (relayed from SLAM via /{robot}/tf)
  {robot}/odom → {robot}/base_footprint  (from odometry)
  {robot}/base_footprint → {robot}/lidar_link → lidar  (static)
"""

import math
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import TransformStamped, PoseStamped
from nav_msgs.msg import Odometry
from tf2_msgs.msg import TFMessage
from tf2_ros import TransformBroadcaster, StaticTransformBroadcaster

DEFAULT_ROBOTS = ['tinyRobot1', 'tinyRobot2', 'tinyRobot3', 'tinyRobot4']


class GlobalTFPublisher(Node):
    def __init__(self):
        super().__init__('global_tf_publisher')

        self.declare_parameter('robot_names', DEFAULT_ROBOTS)
        self.robots = list(self.get_parameter('robot_names').value)

        self.tf_broadcaster = TransformBroadcaster(self)
        self.static_tf_broadcaster = StaticTransformBroadcaster(self)

        self.initial_poses = {}
        self.map_tf_published = set()

        self._publish_sensor_static_transforms()

        for robot in self.robots:
            self.create_subscription(
                Odometry, f'/{robot}/odom',
                lambda msg, r=robot: self._odom_cb(msg, r), 10)

            self.create_subscription(
                TFMessage, f'/{robot}/tf',
                lambda msg, r=robot: self._robot_tf_cb(msg, r), 10)

            self.create_subscription(
                PoseStamped, f'/{robot}/world_pose',
                lambda msg, r=robot: self._world_pose_cb(msg, r), 10)

        self.get_logger().info(
            f'Global TF publisher started for robots: {self.robots}')

    def _publish_sensor_static_transforms(self):
        now = self.get_clock().now().to_msg()
        statics = []

        for robot in self.robots:
            t_lidar = TransformStamped()
            t_lidar.header.stamp = now
            t_lidar.header.frame_id = f'{robot}/base_footprint'
            t_lidar.child_frame_id = f'{robot}/lidar_link'
            t_lidar.transform.translation.x = -0.1
            t_lidar.transform.translation.z = 0.30
            t_lidar.transform.rotation.w = 1.0
            statics.append(t_lidar)

            t_sensor = TransformStamped()
            t_sensor.header.stamp = now
            t_sensor.header.frame_id = f'{robot}/lidar_link'
            t_sensor.child_frame_id = f'{robot}/lidar_link/lidar'
            t_sensor.transform.rotation.w = 1.0
            statics.append(t_sensor)

        self.static_tf_broadcaster.sendTransform(statics)

    def _robot_tf_cb(self, msg: TFMessage, robot_name: str):
        for t in msg.transforms:
            if (t.header.frame_id == f'{robot_name}/map'
                    and t.child_frame_id == f'{robot_name}/odom'):
                self.tf_broadcaster.sendTransform(t)

    def _world_pose_cb(self, msg: PoseStamped, robot_name: str):
        if robot_name in self.map_tf_published:
            return
        self.map_tf_published.add(robot_name)

        t_map = TransformStamped()
        t_map.header.stamp = self.get_clock().now().to_msg()
        t_map.header.frame_id = 'world'
        t_map.child_frame_id = f'{robot_name}/map'
        t_map.transform.translation.x = msg.pose.position.x
        t_map.transform.translation.y = msg.pose.position.y
        t_map.transform.translation.z = msg.pose.position.z
        t_map.transform.rotation = msg.pose.orientation
        self.static_tf_broadcaster.sendTransform([t_map])
        self.get_logger().info(
            f'Published world->{robot_name}/map at '
            f'({msg.pose.position.x:.2f}, {msg.pose.position.y:.2f})')

    def _odom_cb(self, msg: Odometry, robot_name: str):
        t = TransformStamped()
        t.header.stamp = msg.header.stamp if msg.header.stamp.sec > 0 \
            else self.get_clock().now().to_msg()
        t.header.frame_id = f'{robot_name}/odom'
        t.child_frame_id = f'{robot_name}/base_footprint'
        t.transform.translation.x = msg.pose.pose.position.x
        t.transform.translation.y = msg.pose.pose.position.y
        t.transform.translation.z = msg.pose.pose.position.z
        t.transform.rotation = msg.pose.pose.orientation
        self.tf_broadcaster.sendTransform(t)


def main():
    rclpy.init()
    node = GlobalTFPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

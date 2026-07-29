#!/usr/bin/env python3
"""
Publishes the TF transform chain that Nav2 and SLAM Toolbox require.

Subscribes to odometry from DiffDrive (via ros_gz_bridge) and publishes
the dynamic odom→base_footprint TF plus static sensor frame TFs, all on
namespaced /{robot}/tf topics for multi-robot support.

TF chain:
  map -> {robot}/odom          (published by SLAM Toolbox)
  {robot}/odom -> {robot}/base_footprint  (this node, from odometry)
  {robot}/base_footprint -> {robot}/lidar_link  (this node, static)
  {robot}/lidar_link -> {robot}/lidar_link/lidar  (this node, static)
"""

import math
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import TransformStamped
from nav_msgs.msg import Odometry
from tf2_ros import TransformBroadcaster, StaticTransformBroadcaster


class Nav2TFPublisher(Node):
    def __init__(self):
        super().__init__('nav2_tf_publisher')

        self.declare_parameter('robot_name', 'tinyRobot1')
        self.robot_name = self.get_parameter('robot_name').value

        self.odom_frame = f'{self.robot_name}/odom'
        self.base_frame = f'{self.robot_name}/base_footprint'
        self.lidar_frame = f'{self.robot_name}/lidar_link'
        self.lidar_sensor_frame = f'{self.robot_name}/lidar_link/lidar'

        self.tf_broadcaster = TransformBroadcaster(self)
        self.static_tf_broadcaster = StaticTransformBroadcaster(self)

        self._publish_static_transforms()

        self.create_subscription(Odometry, 'odom', self._odom_cb, 10)

        self.get_logger().info(
            f'TF publisher started for {self.robot_name} '
            f'(frames: {self.odom_frame}, {self.base_frame}, {self.lidar_frame})')

    def _publish_static_transforms(self):
        now = self.get_clock().now().to_msg()

        t_base_lidar = TransformStamped()
        t_base_lidar.header.stamp = now
        t_base_lidar.header.frame_id = self.base_frame
        t_base_lidar.child_frame_id = self.lidar_frame
        t_base_lidar.transform.translation.x = -0.1
        t_base_lidar.transform.translation.z = 0.30
        t_base_lidar.transform.rotation.w = 1.0

        t_lidar_sensor = TransformStamped()
        t_lidar_sensor.header.stamp = now
        t_lidar_sensor.header.frame_id = self.lidar_frame
        t_lidar_sensor.child_frame_id = self.lidar_sensor_frame
        t_lidar_sensor.transform.rotation.w = 1.0

        self.static_tf_broadcaster.sendTransform(
            [t_base_lidar, t_lidar_sensor])
        self.get_logger().info(
            f'Published static TF: '
            f'{self.base_frame}->{self.lidar_frame}, '
            f'{self.lidar_frame}->{self.lidar_sensor_frame}')

    def _odom_cb(self, msg: Odometry):
        t = TransformStamped()
        t.header.stamp = msg.header.stamp if msg.header.stamp.sec > 0 \
            else self.get_clock().now().to_msg()
        t.header.frame_id = self.odom_frame
        t.child_frame_id = self.base_frame
        t.transform.translation.x = msg.pose.pose.position.x
        t.transform.translation.y = msg.pose.pose.position.y
        t.transform.translation.z = msg.pose.pose.position.z
        t.transform.rotation = msg.pose.pose.orientation

        self.tf_broadcaster.sendTransform(t)


def main():
    rclpy.init()
    node = Nav2TFPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

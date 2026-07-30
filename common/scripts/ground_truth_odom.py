#!/usr/bin/env python3
"""Ground-truth odometry from Gazebo world poses.

Reads model poses directly from Gazebo's dynamic_pose/info gz-transport
topic via a streaming subprocess, computes odometry relative to each
robot's initial spawn position, and publishes nav_msgs/Odometry on ROS2.

This replaces DiffDrive's broken wheel-joint odometry integration which
produces 10x position errors due to wheel slip in the physics simulation.
"""
import math
import re
import subprocess
import threading
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry

ROBOTS = ['tinyRobot1', 'tinyRobot2']
GZ_TOPIC = '/world/sim_world/dynamic_pose/info'


class GroundTruthOdom(Node):
    def __init__(self):
        super().__init__('ground_truth_odom')
        self.odom_pubs = {
            r: self.create_publisher(Odometry, f'/{r}/odom', 10)
            for r in ROBOTS
        }
        self.initial_poses = {}
        self.latest_poses = {}
        self.lock = threading.Lock()

        t = threading.Thread(target=self._read_gz_poses, daemon=True)
        t.start()

        self.create_timer(0.05, self._publish_odom)
        self.get_logger().info('Ground-truth odom publisher started')

    def _read_gz_poses(self):
        proc = subprocess.Popen(
            ['gz', 'topic', '-e', '-t', GZ_TOPIC],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1)

        cur_name = None
        pos = {}
        rot = {}
        section = None

        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue

            m = re.match(r'name:\s*"(.+)"', line)
            if m:
                cur_name = m.group(1)
                pos = {}
                rot = {}
                section = None
                continue

            if line == 'position {':
                section = 'pos'
                continue
            if line == 'orientation {':
                section = 'rot'
                continue
            if line == '}':
                if section == 'rot' and cur_name in ROBOTS \
                        and 'x' in pos and 'y' in pos \
                        and 'z' in rot and 'w' in rot:
                    with self.lock:
                        self.latest_poses[cur_name] = {
                            'x': pos['x'], 'y': pos['y'],
                            'qz': rot['z'], 'qw': rot['w'],
                        }
                        if cur_name not in self.initial_poses:
                            self.initial_poses[cur_name] = \
                                dict(self.latest_poses[cur_name])
                            self.get_logger().info(
                                f'{cur_name} initial: '
                                f'({pos["x"]:.3f}, {pos["y"]:.3f})')
                section = None
                continue

            vm = re.match(r'(\w+):\s*([0-9eE.+\-]+)', line)
            if vm:
                key, val = vm.group(1), float(vm.group(2))
                if section == 'pos':
                    pos[key] = val
                elif section == 'rot':
                    rot[key] = val

    def _publish_odom(self):
        with self.lock:
            for name in ROBOTS:
                if name not in self.latest_poses \
                        or name not in self.initial_poses:
                    continue

                cur = self.latest_poses[name]
                ini = self.initial_poses[name]

                wyaw = math.atan2(
                    2.0 * cur['qw'] * cur['qz'],
                    1.0 - 2.0 * cur['qz'] ** 2)
                iyaw = math.atan2(
                    2.0 * ini['qw'] * ini['qz'],
                    1.0 - 2.0 * ini['qz'] ** 2)

                dx = cur['x'] - ini['x']
                dy = cur['y'] - ini['y']
                c = math.cos(-iyaw)
                s = math.sin(-iyaw)
                odom_x = dx * c - dy * s
                odom_y = dx * s + dy * c
                odom_yaw = wyaw - iyaw
                while odom_yaw > math.pi:
                    odom_yaw -= 2 * math.pi
                while odom_yaw < -math.pi:
                    odom_yaw += 2 * math.pi

                odom = Odometry()
                odom.header.stamp = self.get_clock().now().to_msg()
                odom.header.frame_id = f'{name}/odom'
                odom.child_frame_id = f'{name}/base_footprint'
                odom.pose.pose.position.x = odom_x
                odom.pose.pose.position.y = odom_y
                odom.pose.pose.orientation.z = math.sin(odom_yaw / 2.0)
                odom.pose.pose.orientation.w = math.cos(odom_yaw / 2.0)
                self.odom_pubs[name].publish(odom)


def main():
    rclpy.init()
    node = GroundTruthOdom()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()

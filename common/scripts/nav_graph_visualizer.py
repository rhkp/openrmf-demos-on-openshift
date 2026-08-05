#!/usr/bin/env python3
"""Publish RMF nav graph as RViz markers matching official rmf_visualization style."""

import math
import yaml
import rclpy
from rclpy.node import Node
from visualization_msgs.msg import Marker, MarkerArray
from geometry_msgs.msg import Point


class NavGraphVisualizer(Node):
    def __init__(self):
        super().__init__('nav_graph_visualizer')
        self.declare_parameter('nav_graph_file', '/opt/rmf/config/collision_test_nav_graph.yaml')
        self.declare_parameter('publish_rate', 1.0)

        nav_graph_file = self.get_parameter('nav_graph_file').value
        rate = self.get_parameter('publish_rate').value

        with open(nav_graph_file, 'r') as f:
            graph = yaml.safe_load(f)

        level = list(graph['levels'].values())[0]
        self.vertices = []
        for v in level['vertices']:
            x, y = float(v[0]), float(v[1])
            props = v[2] if len(v) > 2 else {}
            name = props.get('name', '')
            is_charger = props.get('is_charger', False)
            self.vertices.append((x, y, name, is_charger))

        self.lanes = set()
        for lane in level['lanes']:
            a, b = int(lane[0]), int(lane[1])
            key = (min(a, b), max(a, b))
            self.lanes.add(key)

        self.pub = self.create_publisher(MarkerArray, '/nav_graph_markers', 10)
        self.create_timer(1.0 / rate, self.publish_markers)
        self.get_logger().info(
            f'Nav graph: {len(self.vertices)} waypoints, {len(self.lanes)} lanes'
        )

    def _lane_color(self, a, b):
        x1, y1 = self.vertices[a][0], self.vertices[a][1]
        x2, y2 = self.vertices[b][0], self.vertices[b][1]
        dx, dy = abs(x2 - x1), abs(y2 - y1)
        bypass_ids = {9, 10, 11, 12}
        if a in bypass_ids or b in bypass_ids:
            return (0.95, 0.55, 0.25, 0.55)  # orange for bypass ring
        if dx >= dy:
            return (0.3, 0.5, 1.0, 0.55)  # blue for E-W dominant
        return (0.3, 0.5, 1.0, 0.55)  # blue for N-S too (uniform main corridors)

    def publish_markers(self):
        ma = MarkerArray()
        marker_id = 0
        now = self.get_clock().now().to_msg()

        for a, b in self.lanes:
            x1, y1 = self.vertices[a][0], self.vertices[a][1]
            x2, y2 = self.vertices[b][0], self.vertices[b][1]
            mx, my = (x1 + x2) / 2.0, (y1 + y2) / 2.0
            dx, dy = x2 - x1, y2 - y1
            length = math.sqrt(dx * dx + dy * dy)
            angle = math.atan2(dy, dx)

            r, g, bl, alpha = self._lane_color(a, b)

            m = Marker()
            m.header.frame_id = 'world'
            m.header.stamp = now
            m.ns = 'lanes'
            m.id = marker_id
            m.type = Marker.CUBE
            m.action = Marker.ADD
            m.pose.position.x = mx
            m.pose.position.y = my
            m.pose.position.z = 0.005
            m.pose.orientation.z = math.sin(angle / 2.0)
            m.pose.orientation.w = math.cos(angle / 2.0)
            m.scale.x = length
            m.scale.y = 0.28
            m.scale.z = 0.01
            m.color.r = r
            m.color.g = g
            m.color.b = bl
            m.color.a = alpha
            ma.markers.append(m)
            marker_id += 1

        for i, (x, y, name, is_charger) in enumerate(self.vertices):
            if is_charger:
                rings = [
                    (0.12, 0.5, 1.0, 0.3, 1.0),
                    (0.30, 0.3, 0.9, 0.15, 0.5),
                    (0.50, 0.2, 0.8, 0.1, 0.2),
                ]
            else:
                rings = [
                    (0.10, 0.3, 0.6, 1.0, 0.9),
                    (0.25, 0.2, 0.5, 0.9, 0.4),
                    (0.40, 0.15, 0.4, 0.8, 0.15),
                ]

            for radius, cr, cg, cb, ca in rings:
                m = Marker()
                m.header.frame_id = 'world'
                m.header.stamp = now
                m.ns = 'waypoints'
                m.id = marker_id
                m.type = Marker.CYLINDER
                m.action = Marker.ADD
                m.pose.position.x = x
                m.pose.position.y = y
                m.pose.position.z = 0.01
                m.pose.orientation.w = 1.0
                m.scale.x = radius * 2.0
                m.scale.y = radius * 2.0
                m.scale.z = 0.01
                m.color.r = cr
                m.color.g = cg
                m.color.b = cb
                m.color.a = ca
                ma.markers.append(m)
                marker_id += 1

            if name:
                mt = Marker()
                mt.header.frame_id = 'world'
                mt.header.stamp = now
                mt.ns = 'labels'
                mt.id = marker_id
                mt.type = Marker.TEXT_VIEW_FACING
                mt.action = Marker.ADD
                mt.pose.position.x = x
                mt.pose.position.y = y
                mt.pose.position.z = 0.3
                mt.pose.orientation.w = 1.0
                mt.scale.z = 0.25
                mt.color.r = 1.0
                mt.color.g = 1.0
                mt.color.b = 1.0
                mt.color.a = 0.85
                mt.text = name
                ma.markers.append(mt)
                marker_id += 1

        self.pub.publish(ma)


def main():
    rclpy.init()
    node = NavGraphVisualizer()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()

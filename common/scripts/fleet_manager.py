#!/usr/bin/env python3
"""
Nav2-based Fleet Manager for RMF traffic negotiation.

FastAPI server that bridges the upstream rmf_demos_fleet_adapter HTTP API
to Nav2 NavigateToPose goals. The fleet adapter calls this to navigate/stop
robots; this server transforms world-frame coordinates to the robot's SLAM
frame and sends Nav2 action goals.

Replaces rmf_nav2_bridge.py with proper HTTP-based fleet_manager interface
that the upstream fleet adapter expects.
"""

import math
import os
import sys
import threading
import time
import uvicorn

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
from rclpy.executors import MultiThreadedExecutor

from fastapi import FastAPI, Query
from pydantic import BaseModel
from typing import Optional

from geometry_msgs.msg import PoseStamped, Twist
from nav2_msgs.action import NavigateToPose
from action_msgs.msg import GoalStatus


SPAWN_POSITIONS = {
    'tinyRobot1': {'x': -4.0, 'y': 0.0, 'yaw': 0.0},
    'tinyRobot2': {'x': 4.0, 'y': 0.0, 'yaw': math.pi},
}


class Request(BaseModel):
    map_name: Optional[str] = None
    destination: Optional[dict] = None
    speed_limit: Optional[float] = None
    activity: Optional[str] = None
    label: Optional[str] = None
    toggle: Optional[bool] = None


class Response(BaseModel):
    data: Optional[dict] = None
    success: bool
    msg: str


class FleetManagerNode(Node):
    def __init__(self, robot_name):
        super().__init__('fleet_manager')
        self.robot_name = robot_name

        spawn = SPAWN_POSITIONS.get(
            robot_name,
            {'x': 0.0, 'y': 0.0, 'yaw': 0.0}
        )
        self.spawn_x = float(os.environ.get('SPAWN_X', spawn['x']))
        self.spawn_y = float(os.environ.get('SPAWN_Y', spawn['y']))
        self.spawn_yaw = float(os.environ.get('SPAWN_YAW', spawn['yaw']))

        self.world_x = self.spawn_x
        self.world_y = self.spawn_y
        self.world_yaw = self.spawn_yaw

        self.nav_active = False
        self.nav_goal_handle = None
        self.last_completed_request = None
        self.current_cmd_id = None
        self.lock = threading.Lock()

        self.create_subscription(
            PoseStamped,
            f'/{robot_name}/world_pose',
            self._world_pose_cb, 10
        )

        self.nav_client = ActionClient(
            self, NavigateToPose,
            f'/{robot_name}/navigate_to_pose'
        )

        self.cmd_vel_pub = self.create_publisher(
            Twist, f'/{robot_name}/cmd_vel', 10
        )

        self.get_logger().info(
            f'Fleet manager for {robot_name}, '
            f'spawn=({self.spawn_x:.1f}, {self.spawn_y:.1f}, '
            f'{math.degrees(self.spawn_yaw):.0f}°)'
        )

    def _world_pose_cb(self, msg):
        self.world_x = msg.pose.position.x
        self.world_y = msg.pose.position.y
        qz = msg.pose.orientation.z
        qw = msg.pose.orientation.w
        self.world_yaw = 2.0 * math.atan2(qz, qw)

    def world_to_slam(self, wx, wy, wyaw=0.0):
        dx = wx - self.spawn_x
        dy = wy - self.spawn_y
        c = math.cos(-self.spawn_yaw)
        s = math.sin(-self.spawn_yaw)
        local_x = dx * c - dy * s
        local_y = dx * s + dy * c
        local_yaw = wyaw - self.spawn_yaw
        while local_yaw > math.pi:
            local_yaw -= 2 * math.pi
        while local_yaw < -math.pi:
            local_yaw += 2 * math.pi
        return local_x, local_y, local_yaw

    def get_status(self):
        return {
            'robot_name': self.robot_name,
            'map_name': 'L1',
            'position': {
                'x': self.world_x,
                'y': self.world_y,
                'yaw': self.world_yaw,
            },
            'battery': 100.0,
            'last_completed_request': self.last_completed_request,
            'destination_arrival': None,
        }

    def navigate(self, dest_x, dest_y, dest_yaw, cmd_id, speed_limit=None):
        local_x, local_y, local_yaw = self.world_to_slam(
            dest_x, dest_y, dest_yaw
        )

        self.get_logger().info(
            f'Navigate: world({dest_x:.2f},{dest_y:.2f}) -> '
            f'local({local_x:.2f},{local_y:.2f})'
        )

        if not self.nav_client.wait_for_server(timeout_sec=5.0):
            self.get_logger().error('Nav2 action server not available')
            return False

        with self.lock:
            if self.nav_active and self.nav_goal_handle:
                self.get_logger().info('Canceling previous nav goal')
                self.nav_goal_handle.cancel_goal_async()
                self.nav_active = False

            self.current_cmd_id = cmd_id
            self.nav_active = True

        goal = NavigateToPose.Goal()
        goal.pose.header.frame_id = f'{self.robot_name}/map'
        goal.pose.header.stamp = self.get_clock().now().to_msg()
        goal.pose.pose.position.x = local_x
        goal.pose.pose.position.y = local_y
        goal.pose.pose.orientation.z = math.sin(local_yaw / 2.0)
        goal.pose.pose.orientation.w = math.cos(local_yaw / 2.0)

        future = self.nav_client.send_goal_async(goal)
        future.add_done_callback(self._nav_response_cb)
        return True

    def _nav_response_cb(self, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn('Nav2 goal rejected')
            with self.lock:
                self.nav_active = False
            return

        with self.lock:
            self.nav_goal_handle = goal_handle

        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(self._nav_result_cb)

    def _nav_result_cb(self, future):
        status = future.result().status
        with self.lock:
            self.nav_active = False
            self.nav_goal_handle = None
            if status == GoalStatus.STATUS_SUCCEEDED:
                self.last_completed_request = self.current_cmd_id
                self.get_logger().info(
                    f'Navigation complete (cmd_id={self.current_cmd_id})'
                )
            else:
                self.get_logger().warn(
                    f'Navigation ended with status {status}'
                )

    def stop(self, cmd_id):
        self.get_logger().info(f'Stop requested (cmd_id={cmd_id})')
        with self.lock:
            if self.nav_active and self.nav_goal_handle:
                self.nav_goal_handle.cancel_goal_async()
            self.nav_active = False
            self.nav_goal_handle = None

        stop_msg = Twist()
        self.cmd_vel_pub.publish(stop_msg)
        return True


app = FastAPI()
fleet_node: FleetManagerNode = None


@app.get('/open-rmf/rmf_demos_fm/status')
def get_status(robot_name: str = Query(default=None)):
    if fleet_node is None:
        return Response(success=False, msg='Not initialized')

    if robot_name and robot_name != fleet_node.robot_name:
        return Response(success=False, msg=f'Unknown robot: {robot_name}')

    status = fleet_node.get_status()

    if robot_name:
        return Response(data=status, success=True, msg='')
    else:
        return {
            'all_robots': [status],
            'success': True,
            'msg': '',
        }


@app.post('/open-rmf/rmf_demos_fm/navigate')
def navigate(
    robot_name: str = Query(...),
    cmd_id: str = Query(default='0'),
    request: Request = None,
):
    if fleet_node is None:
        return Response(success=False, msg='Not initialized')

    if robot_name != fleet_node.robot_name:
        return Response(success=False, msg=f'Unknown robot: {robot_name}')

    if not request or not request.destination:
        return Response(success=False, msg='No destination')

    dest = request.destination
    ok = fleet_node.navigate(
        float(dest.get('x', 0)),
        float(dest.get('y', 0)),
        float(dest.get('yaw', 0)),
        cmd_id,
        request.speed_limit,
    )
    return Response(success=ok, msg='' if ok else 'Navigation failed')


@app.get('/open-rmf/rmf_demos_fm/stop_robot')
def stop_robot(
    robot_name: str = Query(...),
    cmd_id: str = Query(default='0'),
):
    if fleet_node is None:
        return Response(success=False, msg='Not initialized')

    if robot_name != fleet_node.robot_name:
        return Response(success=False, msg=f'Unknown robot: {robot_name}')

    ok = fleet_node.stop(cmd_id)
    return Response(success=ok, msg='')


@app.post('/open-rmf/rmf_demos_fm/start_activity')
def start_activity(
    robot_name: str = Query(...),
    cmd_id: str = Query(default='0'),
    request: Request = None,
):
    return Response(success=True, msg='No custom activities')


@app.post('/open-rmf/rmf_demos_fm/toggle_teleop')
def toggle_teleop(
    robot_name: str = Query(...),
    request: Request = None,
):
    return Response(success=True, msg='Teleop not supported')


def run_ros(node, executor):
    try:
        executor.spin()
    except Exception:
        pass


def main():
    robot_name = os.environ.get('ROBOT_NAME', 'tinyRobot1')
    port = int(os.environ.get('FLEET_MANAGER_PORT', '22011'))

    rclpy.init(args=sys.argv)

    global fleet_node
    fleet_node = FleetManagerNode(robot_name)

    executor = MultiThreadedExecutor()
    executor.add_node(fleet_node)

    ros_thread = threading.Thread(target=run_ros, args=(fleet_node, executor))
    ros_thread.daemon = True
    ros_thread.start()

    fleet_node.get_logger().info(f'Starting HTTP server on port {port}')

    uvicorn.run(app, host='0.0.0.0', port=port, log_level='warning')


if __name__ == '__main__':
    main()

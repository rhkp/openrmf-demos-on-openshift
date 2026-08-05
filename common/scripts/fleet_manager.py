#!/usr/bin/env python3
"""
Multi-robot fleet manager for RMF traffic negotiation.

FastAPI server that bridges the upstream rmf_demos_fleet_adapter HTTP API
to Nav2 NavigateToPose goals. A SINGLE instance manages ALL robots in the
fleet — required so the fleet adapter can coordinate intra-fleet traffic
negotiation through rmf_traffic_schedule.

Transforms world-frame coordinates to each robot's SLAM frame before
sending Nav2 goals (robots use SLAM maps, not pre-built maps).
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
    'tinyRobot3': {'x': 0.0, 'y': -4.0, 'yaw': math.pi / 2},
    'tinyRobot4': {'x': 0.0, 'y': 4.0, 'yaw': -math.pi / 2},
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


class RobotState:
    def __init__(self, name, spawn):
        self.name = name
        self.spawn_x = spawn['x']
        self.spawn_y = spawn['y']
        self.spawn_yaw = spawn['yaw']
        self.world_x = self.spawn_x
        self.world_y = self.spawn_y
        self.world_yaw = self.spawn_yaw
        self.nav_active = False
        self.nav_goal_handle = None
        self.last_completed_request = None
        self.current_cmd_id = None
        self.destination_arrival = None
        self.nav_start_time = None
        self.lock = threading.Lock()
        self.nav_client = None
        self.cmd_vel_pub = None


class FleetManagerNode(Node):
    def __init__(self, robot_names):
        super().__init__('fleet_manager')
        self.robots = {}

        for name in robot_names:
            spawn = SPAWN_POSITIONS.get(
                name, {'x': 0.0, 'y': 0.0, 'yaw': 0.0}
            )
            state = RobotState(name, spawn)

            self.create_subscription(
                PoseStamped,
                f'/{name}/world_pose',
                lambda msg, n=name: self._world_pose_cb(n, msg), 10
            )

            state.nav_client = ActionClient(
                self, NavigateToPose,
                f'/{name}/navigate_to_pose'
            )

            state.cmd_vel_pub = self.create_publisher(
                Twist, f'/{name}/cmd_vel', 10
            )

            self.robots[name] = state

            self.get_logger().info(
                f'Registered {name}, '
                f'spawn=({state.spawn_x:.1f}, {state.spawn_y:.1f}, '
                f'{math.degrees(state.spawn_yaw):.0f}°)'
            )

    def _world_pose_cb(self, robot_name, msg):
        state = self.robots.get(robot_name)
        if not state:
            return
        state.world_x = msg.pose.position.x
        state.world_y = msg.pose.position.y
        qz = msg.pose.orientation.z
        qw = msg.pose.orientation.w
        state.world_yaw = 2.0 * math.atan2(qz, qw)

    def world_to_slam(self, state, wx, wy, wyaw=0.0):
        dx = wx - state.spawn_x
        dy = wy - state.spawn_y
        c = math.cos(-state.spawn_yaw)
        s = math.sin(-state.spawn_yaw)
        local_x = dx * c - dy * s
        local_y = dx * s + dy * c
        local_yaw = wyaw - state.spawn_yaw
        while local_yaw > math.pi:
            local_yaw -= 2 * math.pi
        while local_yaw < -math.pi:
            local_yaw += 2 * math.pi
        return local_x, local_y, local_yaw

    def get_status(self, robot_name=None):
        if robot_name:
            state = self.robots.get(robot_name)
            if not state:
                return None
            return self._robot_status(state)
        return [self._robot_status(s) for s in self.robots.values()]

    def _robot_status(self, state):
        return {
            'robot_name': state.name,
            'map_name': 'L1',
            'position': {
                'x': state.world_x,
                'y': state.world_y,
                'yaw': state.world_yaw,
            },
            'battery': 100.0,
            'last_completed_request': state.last_completed_request,
            'destination_arrival': state.destination_arrival,
        }

    def navigate(self, robot_name, dest_x, dest_y, dest_yaw, cmd_id,
                 speed_limit=None):
        state = self.robots.get(robot_name)
        if not state:
            self.get_logger().error(f'Unknown robot: {robot_name}')
            return False

        local_x, local_y, local_yaw = self.world_to_slam(
            state, dest_x, dest_y, dest_yaw
        )

        self.get_logger().info(
            f'{robot_name}: Navigate world({dest_x:.2f},{dest_y:.2f}) -> '
            f'local({local_x:.2f},{local_y:.2f})'
        )

        if not state.nav_client.wait_for_server(timeout_sec=5.0):
            self.get_logger().error(
                f'{robot_name}: Nav2 action server not available'
            )
            return False

        with state.lock:
            if state.nav_active and state.nav_goal_handle:
                self.get_logger().info(
                    f'{robot_name}: Canceling previous nav goal'
                )
                state.nav_goal_handle.cancel_goal_async()
                state.nav_active = False

            state.current_cmd_id = cmd_id
            state.nav_active = True
            state.destination_arrival = None
            state.nav_start_time = time.time()

        goal = NavigateToPose.Goal()
        goal.pose.header.frame_id = f'{robot_name}/map'
        goal.pose.header.stamp = self.get_clock().now().to_msg()
        goal.pose.pose.position.x = local_x
        goal.pose.pose.position.y = local_y
        goal.pose.pose.orientation.z = math.sin(local_yaw / 2.0)
        goal.pose.pose.orientation.w = math.cos(local_yaw / 2.0)

        future = state.nav_client.send_goal_async(goal)
        future.add_done_callback(
            lambda f, s=state: self._nav_response_cb(s, f)
        )
        return True

    def _nav_response_cb(self, state, future):
        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().warn(f'{state.name}: Nav2 goal rejected')
            with state.lock:
                state.nav_active = False
            return

        with state.lock:
            state.nav_goal_handle = goal_handle

        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(
            lambda f, s=state: self._nav_result_cb(s, f)
        )

    def _nav_result_cb(self, state, future):
        status = future.result().status
        with state.lock:
            state.nav_active = False
            state.nav_goal_handle = None
            if status == GoalStatus.STATUS_SUCCEEDED:
                state.last_completed_request = state.current_cmd_id
                duration = time.time() - (state.nav_start_time or 0)
                state.destination_arrival = {
                    'cmd_id': state.current_cmd_id,
                    'duration': duration,
                }
                self.get_logger().info(
                    f'{state.name}: Navigation complete '
                    f'(cmd_id={state.current_cmd_id})'
                )
            else:
                self.get_logger().warn(
                    f'{state.name}: Navigation ended with status {status}'
                )

    def stop(self, robot_name, cmd_id):
        state = self.robots.get(robot_name)
        if not state:
            return False

        self.get_logger().info(
            f'{robot_name}: Stop requested (cmd_id={cmd_id})'
        )
        with state.lock:
            if state.nav_active and state.nav_goal_handle:
                state.nav_goal_handle.cancel_goal_async()
            state.nav_active = False
            state.nav_goal_handle = None

        stop_msg = Twist()
        state.cmd_vel_pub.publish(stop_msg)
        return True


app = FastAPI()
fleet_node: FleetManagerNode = None


@app.get('/open-rmf/rmf_demos_fm/status')
def get_status(robot_name: str = Query(default=None)):
    if fleet_node is None:
        return Response(success=False, msg='Not initialized')

    if robot_name:
        status = fleet_node.get_status(robot_name)
        if status is None:
            return Response(
                success=False, msg=f'Unknown robot: {robot_name}'
            )
        return Response(data=status, success=True, msg='')
    else:
        all_statuses = fleet_node.get_status()
        return {
            'all_robots': all_statuses,
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

    if robot_name not in fleet_node.robots:
        return Response(success=False, msg=f'Unknown robot: {robot_name}')

    if not request or not request.destination:
        return Response(success=False, msg='No destination')

    dest = request.destination
    ok = fleet_node.navigate(
        robot_name,
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

    if robot_name not in fleet_node.robots:
        return Response(success=False, msg=f'Unknown robot: {robot_name}')

    ok = fleet_node.stop(robot_name, cmd_id)
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
    robot_names_str = os.environ.get(
        'ROBOT_NAMES',
        os.environ.get('ROBOT_NAME', 'tinyRobot1')
    )
    robot_names = [n.strip() for n in robot_names_str.split(',')]
    port = int(os.environ.get('FLEET_MANAGER_PORT', '22011'))

    rclpy.init(args=sys.argv)

    global fleet_node
    fleet_node = FleetManagerNode(robot_names)

    executor = MultiThreadedExecutor()
    executor.add_node(fleet_node)

    ros_thread = threading.Thread(target=run_ros, args=(fleet_node, executor))
    ros_thread.daemon = True
    ros_thread.start()

    fleet_node.get_logger().info(
        f'Starting HTTP server on port {port} for robots: {robot_names}'
    )

    uvicorn.run(app, host='0.0.0.0', port=port, log_level='warning')


if __name__ == '__main__':
    main()

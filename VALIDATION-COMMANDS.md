# Robot-as-Pod Validation Commands

## Quick Validation Tests

### 1. Deploy Traditional Mode (Baseline)
```bash
# Deploy with existing single-pod architecture
helm install rmf-office-demo office/helm/ \
  --set robots.enabled=false \
  --namespace arhkp1-openrmf

# Verify single simulation pod
kubectl get pods -l app.kubernetes.io/name=openrmf-office-demo
# Expected: rmf-office-demo-xxxxx (1 pod with simulation+fleet-monitor+task-dispatch)

# Test existing functionality
kubectl logs deployment/rmf-office-demo -c task-dispatch
# Expected: "Dispatching patrol: coe -> lounge (3 loops)..."
```

### 2. Deploy Robot-as-Pod Mode
```bash  
# Deploy with new distributed architecture
helm upgrade rmf-office-demo office/helm/ \
  --set robots.enabled=true \
  --namespace arhkp1-openrmf

# Verify distributed pods
kubectl get pods -l app.kubernetes.io/name=openrmf-office-demo
# Expected: 
# - rmf-office-demo-xxxxx (simulation-world + fleet-coordinator)
# - rmf-office-demo-robot-tinyrobot1-xxxxx (robot pod)
# - rmf-office-demo-robot-tinyrobot2-xxxxx (robot pod)

# Check robot pod components
kubectl get pods -l app.kubernetes.io/component=robot
kubectl get pods -l rmf.openrobotics.org/robot=tinyRobot1
```

### 3. Validate Communication
```bash
# Check Zenoh router connectivity
kubectl logs deployment/rmf-office-demo-zenoh-router

# Monitor fleet coordinator 
kubectl logs deployment/rmf-office-demo -c fleet-coordinator -f

# Watch individual robots
kubectl logs deployment/rmf-office-demo-robot-tinyrobot1 -c robot-adapter -f
kubectl logs deployment/rmf-office-demo-robot-tinyrobot2 -c robot-adapter -f

# Check task dispatch in robot mode
kubectl logs deployment/rmf-office-demo -c robot-task-dispatch -f
```

### 4. Test Resource Allocation
```bash
# Monitor resource usage
kubectl top pods -l app.kubernetes.io/name=openrmf-office-demo

# Compare traditional vs robot-pod mode resource totals
# Traditional: ~2-4 CPU total in single pod
# Robot-pod: ~1-2 CPU (world) + 2x 0.5-1 CPU (robots) + 0.25-0.5 CPU (coordinator)
```

### 5. Fault Tolerance Testing
```bash
# Kill a robot pod and verify recovery
kubectl delete pod -l rmf.openrobotics.org/robot=tinyRobot1
kubectl get pods -l rmf.openrobotics.org/robot=tinyRobot1
# Should restart automatically

# Check fleet continues operating
kubectl logs deployment/rmf-office-demo -c fleet-coordinator
```

### 6. Dashboard Access
```bash
# Port forward to RMF Web dashboard (if enabled)
kubectl port-forward service/rmf-office-demo-dashboard 3000:3000

# Open http://localhost:3000
# Verify both robots visible in fleet view
# Verify task execution shows robot coordination
```

## Expected Results

### ✅ Success Criteria

1. **Functional Equivalence**
   - Same patrol behavior: coe → lounge (3 loops)
   - Both robots receive and execute tasks
   - Web dashboard shows both robots

2. **Distributed Architecture**  
   - 3-4 pods instead of 1 pod
   - Robot pods have individual resource limits
   - Fleet coordinator manages distributed robots

3. **Communication**
   - All pods connect to Zenoh router
   - `/fleet_states` topic aggregates both robots
   - Task assignment reaches individual robots

4. **Resource Optimization**
   - Total resource usage similar or better than baseline
   - Simulation pod reduced when world-only
   - Individual robot pods properly sized

5. **Fault Tolerance**
   - Individual robot pod restart doesn't affect simulation
   - Fleet continues with remaining robots
   - Graceful robot re-joining after restart

### 🚨 Troubleshooting

If robots don't start:
```bash
# Check world simulation readiness
kubectl logs deployment/rmf-office-demo -c simulation | grep "world"

# Check robot waiting for world
kubectl logs deployment/rmf-office-demo-robot-tinyrobot1 | grep "wait"

# Verify Zenoh connectivity
kubectl logs deployment/rmf-office-demo-robot-tinyrobot1 | grep -i zenoh
```

If tasks not dispatching:
```bash
# Check fleet states topic
kubectl exec -it deployment/rmf-office-demo-robot-tinyrobot1 -- ros2 topic echo /fleet_states --once

# Monitor task dispatch
kubectl logs deployment/rmf-office-demo -c robot-task-dispatch
```

## Next Steps

Once validation passes, this foundation enables:

1. **Phase 2**: Individual robot navigation systems (Nav2 vs RMF per robot)
2. **Phase 3**: Robot-to-robot communication (sensor data, IDs, proximity)
3. **Scaling**: Add more robot instances via configuration
4. **Different demos**: Apply same pattern to hotel/airport demos
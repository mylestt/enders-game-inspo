//==========================================( Neverway 2026 )=========================================================//
// Author
//
//
// Contributors
//
//
//====================================================================================================================//


using Godot;
using System;
using System.Collections.Generic;

public partial class BoundaryPushback : Area3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/

	[Export] public float pushStrength = 6.0f;
	[Export] public float maxPushSpeed = 40.0f;
	[Export] public NodePath centerOverride;

	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	private Node3D center;
	private readonly HashSet<RigidBody3D> outsideBodies = new HashSet<RigidBody3D>();


	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		center = centerOverride != null && !centerOverride.IsEmpty
			? GetNodeOrNull<Node3D>(centerOverride)
			: this;

		BodyEntered += OnBodyEntered;
		BodyExited += OnBodyExited;
	}

	public override void _PhysicsProcess(double delta)
	{
		if (outsideBodies.Count == 0)
			return;

		Vector3 centerPos = center != null ? center.GlobalPosition : GlobalPosition;

		RigidBody3D[] bodies = new RigidBody3D[outsideBodies.Count];
		outsideBodies.CopyTo(bodies);

		foreach (RigidBody3D body in bodies)
		{
			if (!GodotObject.IsInstanceValid(body))
			{
				outsideBodies.Remove(body);
				continue;
			}

			ApplyPushback(body, centerPos, (float)delta);
		}
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void OnBodyEntered(Node3D body)
	{
		if (body is RigidBody3D rigidBody)
			outsideBodies.Remove(rigidBody);
	}

	private void OnBodyExited(Node3D body)
	{
		if (!(body is RigidBody3D rigidBody))
			return;

		if (!IsLocalPlayer(rigidBody))
			return;

		outsideBodies.Add(rigidBody);
	}

	private bool IsLocalPlayer(Node3D body)
	{
		if (!body.HasMethod("get_peer_id"))
			return false;

		Variant isLocalVariant = body.Get("is_local_player");
		return isLocalVariant.VariantType == Variant.Type.Bool && isLocalVariant.AsBool();
	}

	private void ApplyPushback(RigidBody3D body, Vector3 centerPos, float delta)
	{
		Vector3 toCenter = centerPos - body.GlobalPosition;
		float distance = toCenter.Length();

		if (distance < 0.001f)
			return;

		Vector3 inward = toCenter / distance;

		float desiredInwardSpeed = Mathf.Min(pushStrength * distance, maxPushSpeed);
		float currentInwardSpeed = body.LinearVelocity.Dot(inward);

		if (currentInwardSpeed < desiredInwardSpeed)
		{
			float add = Mathf.Min(desiredInwardSpeed - currentInwardSpeed, pushStrength * delta * 4.0f);
			body.LinearVelocity += inward * add;
		}

		body.Sleeping = false;
	}

	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}

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

public partial class GravityWell : Area3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	[Export] public float gravityStrength = 40.0f;
	[Export] public float maxPullSpeed = 25.0f;
	[Export] public float minFalloffDistance = 1.5f;
	[Export] public NodePath centerOverride;

	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	private Node3D center;
	private readonly HashSet<RigidBody3D> insideBodies = new HashSet<RigidBody3D>();


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
		if (insideBodies.Count == 0)
			return;

		Vector3 centerPos = center != null ? center.GlobalPosition : GlobalPosition;

		RigidBody3D[] bodies = new RigidBody3D[insideBodies.Count];
		insideBodies.CopyTo(bodies);

		foreach (RigidBody3D body in bodies)
		{
			if (!GodotObject.IsInstanceValid(body))
			{
				insideBodies.Remove(body);
				continue;
			}

			ApplyPull(body, centerPos, (float)delta);
		}
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void OnBodyEntered(Node3D body)
	{
		if (!(body is RigidBody3D rigidBody))
			return;

		if (!IsLocalPlayer(rigidBody))
			return;

		insideBodies.Add(rigidBody);
	}

	private void OnBodyExited(Node3D body)
	{
		if (body is RigidBody3D rigidBody)
			insideBodies.Remove(rigidBody);
	}

	private bool IsLocalPlayer(Node3D body)
	{
		if (!body.HasMethod("get_peer_id"))
			return false;

		Variant isLocalVariant = body.Get("is_local_player");
		return isLocalVariant.VariantType == Variant.Type.Bool && isLocalVariant.AsBool();
	}

	private void ApplyPull(RigidBody3D body, Vector3 centerPos, float delta)
	{
		Vector3 toCenter = centerPos - body.GlobalPosition;
		float distance = toCenter.Length();

		if (distance < 0.05f)
			return;

		Vector3 inward = toCenter / distance;

		float falloffDistance = Mathf.Max(distance, minFalloffDistance);
		float accel = gravityStrength / (falloffDistance * falloffDistance);

		body.LinearVelocity += inward * Mathf.Min(accel * delta, maxPullSpeed);
		body.Sleeping = false;
	}

	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}


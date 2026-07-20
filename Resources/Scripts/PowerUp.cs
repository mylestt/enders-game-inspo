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

public partial class PowerUp : Area3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	public enum PowerUpType
	{
		Health,
		Shield,
		DamageMultiplier,
		Invisibility
	}

	[Export] public PowerUpType type = PowerUpType.Health;
	[Export] public float respawnSeconds = 15.0f;

	[Export] public float healAmount = 50.0f;

	[Export] public float shieldDuration = 8.0f;
	[Export(PropertyHint.Range, "0,1")] public float shieldDamageReduction = 0.5f;

	[Export] public float damageMultiplierValue = 2.0f;
	[Export] public float damageMultiplierDuration = 8.0f;

	[Export] public float invisibilityDuration = 8.0f;

	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	[Export] public NodePath visualPath = "Visual";
	private Node3D visual;
	private float respawnRemaining = 0.0f;

	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		visual = GetNodeOrNull<Node3D>(visualPath);
		BodyEntered += OnBodyEntered;
	}

	public override void _Process(double delta)
	{
		if (respawnRemaining <= 0.0f)
			return;

		respawnRemaining -= (float)delta;

		if (respawnRemaining <= 0.0f)
		{
			if (visual != null) visual.Visible = true;
			Monitoring = true;
		}
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void OnBodyEntered(Node3D body)
	{
		if (!body.HasMethod("get_peer_id")) return;

		bool isLocal = body.Get("is_local_player").AsBool();
		if (!isLocal) return;

		bool isDead = body.Get("is_dead").AsBool();
		if (isDead) return;

		ApplyEffect(body);

		if (visual != null) visual.Visible = false;
		Monitoring = false;
		respawnRemaining = respawnSeconds;
	}

	private void ApplyEffect(Node3D player)
	{
		switch (type)
		{
			case PowerUpType.Health:
				if (player.HasMethod("apply_powerup_heal"))
					player.Call("apply_powerup_heal", healAmount);
				break;

			case PowerUpType.Shield:
				if (player.HasMethod("activate_shield"))
					player.Call("activate_shield", shieldDuration, shieldDamageReduction);
				break;

			case PowerUpType.DamageMultiplier:
				if (player.HasMethod("activate_damage_multiplier"))
					player.Call("activate_damage_multiplier", damageMultiplierValue, damageMultiplierDuration);
				break;

			case PowerUpType.Invisibility:
				if (player.HasMethod("activate_invisibility"))
					player.Call("activate_invisibility", invisibilityDuration);
				break;
		}
	}


	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}

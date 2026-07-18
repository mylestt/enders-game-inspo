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

public partial class KillZone : Area3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	[Export] public float damageAmount = 99999.0f;

	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/


	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		BodyEntered += OnBodyEntered;
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void OnBodyEntered(Node3D body)
	{
		if (!body.HasMethod("get_peer_id")) return;

		bool isLocal = body.Get("is_local_player").AsBool();
		if (!isLocal) return;

		bool isDead = body.Get("is_dead").AsBool();
		if (isDead) return;

		int peerId = body.Call("get_peer_id").AsInt32();
		Node networkManager = body.Get("network_manager").As<Node>();

		if (networkManager == null || !networkManager.HasMethod("request_environmental_kill"))
		{
			if (body.HasMethod("apply_weapon_damage"))
				body.Call("apply_weapon_damage", damageAmount, 0);

			return;
		}

		networkManager.Call("request_environmental_kill", peerId, damageAmount);
	}

	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}


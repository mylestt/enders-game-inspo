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
		GD.Print("KillZone saw body enter: ", body.Name);
		if (!body.HasMethod("get_peer_id")) return;
		GD.Print("Got peer");

		bool isLocal = body.Get("is_local_player").AsBool();
		if (!isLocal) return;
		GD.Print("Got local");

		bool isDead = body.Get("is_dead").AsBool();
		if (isDead) return;
		GD.Print("Got alive");

		if (body.HasMethod("apply_weapon_damage"))
			body.Call("apply_weapon_damage", damageAmount, 0);
	}

	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}


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

public partial class FlagCaptureZone : Area3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/


	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	[Export] public NodePath flagPath;
	private Flag flag;
	private Node roundManager;

	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		flag = GetNode<Flag>(flagPath);
		BodyEntered += OnBodyEntered;
	}

	public override void _Process(double delta)
	{
		Node rm = GetRoundManager();
		bool isCtf = rm != null && rm.HasMethod("is_ctf") && rm.Call("is_ctf").AsBool();

		Monitoring = isCtf;
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private Node GetRoundManager()
	{
		if (roundManager != null && GodotObject.IsInstanceValid(roundManager))
			return roundManager;

		roundManager = GetTree().Root.FindChild("RoundManager", true, false);
		return roundManager;
	}

	private void OnBodyEntered(Node3D body)
	{
		if (flag == null) return;
		if (!body.HasMethod("get_peer_id")) return;

		bool isLocal = body.Get("is_local_player").AsBool();
		if (!isLocal) return;

		int peerId = body.Call("get_peer_id").AsInt32();

		if (flag.carrierPeerId != peerId) return;

		flag.RequestCapture(peerId);
	}



	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}


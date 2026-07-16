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

public partial class PlayerNametag : Label3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	[Export] public float labelHeight = 1.7f;


	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/


	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	
	public override void _Ready()
	{
		Position = new Vector3(0f, labelHeight, 0f);
		Billboard = BaseMaterial3D.BillboardModeEnum.Enabled;
		Visible = false;
	}

	public void Setup(bool isLocalPlayer, int peerId, Node networkManager)
	{
		Visible = !isLocalPlayer;

		if (isLocalPlayer || networkManager == null) return;

		Text = networkManager.Call("get_player_name", peerId).AsString();
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/


	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/


	#endregion
}


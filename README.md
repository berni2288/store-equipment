store-equipment
============

### Description
Store module that allows players to buy custom wearable items in the store (hats, armors, or anything the administrator sets in the server) to customize the visuals of the characters. This plugin is not supported in TF2 due to Valve's policy on attachments.

### Requirements

* [Store](https://forums.alliedmods.net/showthread.php?t=207157)
* [SDKHooks](http://forums.alliedmods.net/showthread.php?t=106748) 
* [SMJansson](https://forums.alliedmods.net/showthread.php?t=184604)

### Features

* **Custom attachments** - You can set different attachments for every equipment item, not just the `forward` attachment.
* **Support for custom player models** - You can set different positions and angles for every player model that you have in your server.
* **Zombie:Reloaded support** (optional) - Only humans can wear equipment.
* **ToggleEffects support** (optional)
* **Models and materials are downloaded automatically** - You don't need to configure that.

### Installation

Download the `store-equipment.zip` archive from the plugin thread and extract to your `sourcemod` folder intact. Download [Accessories Pack](http://www.garrysmod.org/downloads/?a=view&id=97791) and extract it to your game directory. Then, navigate to `configs/store/sql-init-scripts/` and execute `equipment.sql` in your database.

### Adding More Equipment

Until the web panel for the store will be ready, you'll need to update the database directly to add more items. To do that, open your phpMyAdmin and duplicate one of the existing hats or miscs you have. Change `name`, `display_name`, `description` and `attrs` to customize the new equipment. 

If you don't want to support any custom player models, the attrs field should look like:

    {
        "model": "models/sam/antlers.mdl",
        "position": [0, 0, 2.4],
        "angles": [0, 0, 0],
        "attachment": "forward"
    }

If you do have custom player models, you'll need to extend it with the playermodels property:

    {
        "model": "models/props_junk/trafficcone001a.mdl",
        "position": [0.0, -1.0, 20.0],
        "angles": [0.0, 0.0, 0.0],
        "attachment": "forward",
        "playermodels": [
            {
                "playermodel": "models/player/techknow/scream/scream.mdl",
                "position": [0, -5.4, 20],
                "angles": [0, 0, 90]
            },
            {
                "playermodel": "models/player/csctm/bandit/black.mdl",
                "position": [0, -5.4, 20],
                "angles": [0, 0, 90]
            }
        ]
    }

# dc-ranked_queue
# Discord Queue Manager

This is a Python program that acts as a queue manager for a Discord server. It allows users to join a queue and form balanced teams for games or other activities.

## How it Works

1. Users can join the queue by clicking the "Join Queue" button on the Discord server.
2. Once the queue reaches the specified size, the program automatically creates balanced teams based on the users' ranking.
3. The teams are displayed on a separate text channel along with the team captains.
4. Team captains can add players to their respective teams by clicking on the player's name button.
5. The teams and player list are updated in real-time on the Discord server.

## Features

- Allows users to join a queue and leave the queue.
- Automatically creates balanced teams based on ranking.
- Supports custom queue size.
- Ability for team captains to add players to their teams.
- Real-time updates on the Discord server.

## Usage

1. Fill in the required parameters in the `config.py` file, including your bot token, main channel ID, category channel ID, and other settings.
2. Run the program using the `QueueManager.runBot()` method.

## Dependencies

- discord.py
- asyncio

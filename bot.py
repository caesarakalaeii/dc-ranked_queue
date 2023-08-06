import discord
from discord.ext import commands
from discord.ui import Button, View
from logger import Logger
import asyncio
from config import *

 
class RankingHandler():
    
    def __init__(self, display_name:str, parse_ranking = False):
        self.parse_ranking = parse_ranking
        if self.parse_ranking:
            splits = display_name.split("-")
            for split in splits:
                split.replace(" ", "")
            rank = splits[0]
        else:
            rank = 0
        self.name = display_name
        self.rank = rank
        
        
    def __lt__(self, other):
        return self.rank < other.rank   
    
class Teams():
    team1 :list
    team2 :list
    
    def __init__(self, captains):
        self.captain1 = captains[0]
        self.captain2 = captains[1]
        self.team1 = []
        self.team2 = []
        self.team1_str = f'Team1:\nCaptain: {self.captain1.mention}\nPlayers:\n'
        self.team2_str = f'Team2:\nCaptain: {self.captain2.mention}\nPlayers:\n'
    
    def addTeam1(self,user):
        self.team1.append(user)
        self.team1_str += f'{user.mention}\n'
    
    def addTeam2(self,user):
        self.team2.append(user)
        self.team2_str += f'{user.mention}\n'


class CustomQueue():
    
    def __init__(self, queue_size, parse_ranking = True):
        self.queue_size = queue_size
        self.queue = asyncio.Queue(maxsize=queue_size)
        self.users = []
        self.parse_ranking = parse_ranking
    
    async def put(self, user:discord.User):
        
        u = RankingHandler(user.display_name, self.parse_ranking)
        for us in self.users:
            if us.name == u.name:
                return
        self.users.append(u)
        await self.queue.put(user)
    
    async def remove(self, user:discord.User):
        temp_queue = asyncio.Queue(self.queue_size)
        while not self.queue.empty():
            quser = await self.queue.get()
            if user == quser:
                for user_rank in self.users:
                    if user_rank.name == user.display_name:
                        del self.users[self.users.index(user_rank)]
            else:
                temp_queue.put_nowait(quser)
                self.queue.task_done()
        self.queue = temp_queue
    
    async def dissolve(self):
        users_objs = []
        while not self.queue.empty():
            user_obj = await self.queue.get()
            users_objs.append(user_obj)
            self.queue.task_done()
        users = self.users
        self.users = []
        return users_objs, users
    
    
class QueueManager():
    guild: discord.Guild
    teams: Teams
    
    def __init__(self, bot_token: str, main_channel_id: int, category_channel_id:int, 
                 queue_size:int = 6, parse_ranking:bool = True, console_log: bool = True, 
                 file_log:bool = True):
        
        self.bot_token = bot_token
        self.channel_id = main_channel_id
        self.category_channel_id = category_channel_id
        self.queue_size = queue_size
        self.parse_ranking = parse_ranking
        self.l = Logger(console_log=console_log, file_logging=file_log)
        self.intents = discord.Intents.default()
        self.intents.message_content = True
        self.intents.reactions = True
        self.queue = CustomQueue(queue_size, parse_ranking)
        self.embed_description = f'Current config:\nQueue size:{self.queue_size}\nParse Ranking: {self.parse_ranking}\n'
        self.guild = None
        self.teams = None

    def runBot(self):
        bot = commands.Bot(command_prefix='!', intents=self.intents)
        self.bot = bot
        @bot.event
        async def on_ready():
            self.l.passing(f'Logged in as {bot.user.name}')
            await self.create_embed()
            cat_channel = self.guild.get_channel(self.category_channel_id)
            channels = cat_channel.channels
            self.l.warning(f'pruging stale channels')
            for channel in channels:
                if len(cat_channel.channels) > 20:
                    await channel.delete()
            
            self.l.passing("Waiting for interactions...")
            @bot.event
            async def on_interaction(interaction):
                self.l.passingblue("User interacted")
                await self.handle_interaction(interaction)
        bot.run(self.bot_token)
    
    async def create_embed(self):
        channel = self.bot.get_channel(self.channel_id)
        self.guild = channel.guild
        self.l.warning(f'pruging stale embeds')
        async for message in channel.history():
            await message.delete()
        self.l.passing(f"Creating embed")
        embed = discord.Embed(title='Queue', description=self.embed_description)

        button1 = Button(style=discord.ButtonStyle.green, label='Join queue', custom_id='join_queue')
        button2 = Button(style=discord.ButtonStyle.red, label='Leave queue', custom_id='leave_queue')

        view = View(timeout=None)
        view.add_item(button1)
        view.add_item(button2)
        self.view = view
        
        await channel.send(embed=embed, view=view)
        
    async def handle_interaction(self, interaction: discord.Interaction):
        user = interaction.user
        action = interaction.data['custom_id']
        if action == 'join_queue':
            self.l.passingblue(f'{user.display_name} joined the queue')
            await self.queue.put(user)
            await self.handleQueue()
        elif action == 'leave_queue':
            self.l.passingblue(f'{user.display_name} left the queue')
            await self.queue.remove(user)
        elif 'player_add' in action:
            self.l.passingblue(f'{user.display_name} attempting to add player to team')
            await self.add_player(interaction)
            await self.updatePlayerEmbed(interaction)
            return
        
        await self.updateEmbed(interaction)
        
    async def add_player(self, interaction: discord.Interaction):
        user = interaction.user
        user_name = user.display_name
        playername = interaction.data['custom_id'].removeprefix("player_add_")
        player = RankingHandler(playername, self.parse_ranking)
        p = None
        for u in self.user_obj:
            if player.name == u.display_name:
                p = u
                break
        if user_name == self.teams.captain1.display_name and (len(self.teams.team1) < len(self.teams.team2) or len(self.teams.team1) == 0):
            self.teams.addTeam1(p)
            await self.removeFromView(player)
        elif user_name == self.teams.captain2.display_name and len(self.teams.team2) <= len(self.teams.team1):
            
            self.teams.addTeam2(p)
            await self.removeFromView(player)
        
        
      
    async def updatePlayerEmbed(self, interaction: discord.Interaction):
        embed = await self.playerEmbed(self.teams)
        await interaction.response.edit_message(embed= embed, view=self.player_view)
      
    async def handleTeams(self):
        self.user_obj, self.users = await self.queue.dissolve()
        self.users.sort()
        game_id = 0
        cat_channel = self.guild.get_channel(self.category_channel_id)
        channels = cat_channel.channels
        if len(channels)>20:
            channels[0].delete()
        for channel in channels:
            if channel.name == f"game-{game_id}":
                game_id +=1
                continue
            else:
                break
        channel = await cat_channel.create_text_channel(f"Game {game_id}")
        user_str = ''
        captain_objs = []
        for user in self.users:
            user_str += f'\n{user.name} Rank: {user.rank}'
        captains = self.users[:2]
        for cap in captains:
            for u in self.user_obj:
                if cap.name == u.display_name:
                    captain_objs.append(u)
                    break
        self.select_view = await self.createView(self.users)
        self.teams = Teams(captain_objs)
        embed = await self.playerEmbed(self.teams)
        await channel.send(embed=embed, view=self.select_view)    
            
    async def updateEmbed(self, interaction: discord.Interaction):
        queue_str = ''
        for userrec in self.queue.users:
            queue_str += f'{userrec.name} Rank: {userrec.rank}\n'
        queue_str += f'Queue : {len(self.queue.users)}\\{self.queue_size}'
        embed = discord.Embed(title='Queue', description=self.embed_description + queue_str)
        await interaction.response.edit_message(embed= embed, view=self.view)
       
    async def createView(self, users):
        view = View(timeout=None)
        players = users[2:]
        for user in players:
            b = Button(style=discord.ButtonStyle.green, label=f'{user.name}', custom_id=f'player_add_{user.name}')
            view.add_item(b)
        self.player_view =view
        return view
    
    async def removeFromView(self, user):
        items = self.player_view.children
        for item in items:
            if item.label == user.name:
                self.player_view.remove_item(item)
        
    async def handleQueue(self):
        
        if self.queue.queue.full():
            
            await self.handleTeams()
            return True
                
        else: 
            return False
        
    async def playerEmbed(self, teams:Teams):
        
       return discord.Embed(title = 'Teams:', description=teams.team1_str + teams.team2_str)


if __name__ == '__main__':
    bot = QueueManager(BOT_TOKEN, 1137736500956631091, 1137736261549969488, 6, parse_ranking= False)
    
    bot.runBot()



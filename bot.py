import discord
from discord.ext import commands
from discord.ui import Button, View
from logger import Logger
import asyncio
from config import *

class RankingHandler():
    
    def __init__(self, name:str, rank:int) -> None:
        self.name = name
        self.rank = rank
    def __lt__(self, other):
        return self.rank < other.rank
class CustomQueue():
    
    def __init__(self, queue_size, parse_ranking = True):
        self.queue_size = queue_size
        self.queue = asyncio.Queue(maxsize=queue_size)
        self.users = []
        self.parse_ranking = parse_ranking
    
    async def put(self, user:discord.User):
        if self.parse_ranking:
            splits = user.display_name.split("-")
            for split in splits:
                split.replace(" ", "")
            rank = splits[0]
        else:
            rank = 0
        u = RankingHandler(user.display_name, rank)
        for user in self.users:
            if user.name == u.name:
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

    def runBot(self):
        bot = commands.Bot(command_prefix='!', intents=self.intents)
        self.bot = bot
        @bot.event
        async def on_ready():
            self.l.passing(f'Logged in as {bot.user.name}')
            await self.create_embed()
            self.l.passing("Waiting for interactions...")
            @bot.event
            async def on_interaction(interaction):
                await self.handle_interaction(interaction)
        bot.run(self.bot_token)
    
    async def create_embed(self):
        self.l.passing(f"Creating embed")
        embed = discord.Embed(title='Queue', description=self.embed_description)

        button1 = Button(style=discord.ButtonStyle.primary, label='Join queue', custom_id='join_queue')
        button2 = Button(style=discord.ButtonStyle.secondary, label='Leave queue', custom_id='leave_queue')

        view = View()
        view.add_item(button1)
        view.add_item(button2)
        channel = self.bot.get_channel(self.channel_id)
        self.guild = channel.guild
        self.view = view
        
        await channel.send(embed=embed, view=view)
        
    async def handle_interaction(self, interaction: discord.Interaction):
        user = interaction.user
        action = interaction.data['custom_id']
        if action == 'join_queue':
            await self.queue.put(user)
            await self.handleQueue()
        elif action == 'leave_queue':
            await self.queue.remove(user)
        
        await self.updateEmbed(interaction)
        
            
    async def updateEmbed(self, interaction: discord.Interaction):
        queue_str = ''
        for userrec in self.queue.users:
            queue_str += f'{userrec.name} Rank: {userrec.rank}\n'
        queue_str += f'Queue : {len(self.queue.users)}\\{self.queue_size}'
        embed = discord.Embed(title='Queue', description=self.embed_description + queue_str)
        await interaction.response.edit_message(embed= embed, view=self.view)
        
    async def handleQueue(self):
        
        if self.queue.queue.full():
            
            user_obj, users = await self.queue.dissolve()
                
            users.sort()
            cap1 = users[0]
            cap2 = users[1]
            
            game_id = 0
            cat_channel = self.guild.get_channel(self.category_channel_id)
            for channel in cat_channel.channels:
                if channel.name == f"game-{game_id}":
                    game_id +=1
                    continue
                else:
                    break
            channel = await cat_channel.create_text_channel(f"Game {game_id}")
            user_str = ''
            for user in users:
                user_str += f'\n{user.name} Rank: {user.rank}'
            await channel.send(f"Users are: {user_str}")
            return True
                
        else: 
            return False


if __name__ == '__main__':
    bot = QueueManager(BOT_TOKEN, 1137510597114744882, 1137543651401150606, 2, parse_ranking= False)
    
    bot.runBot()



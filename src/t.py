import gturtle as g
import time
import math


def deg2rad(angle):
    return angle * math.pi / 180


g.makeTurtle()

# g.hideTurtle()
sides = 9
len = 100
g.setPos(len, 0)


def calc(angle):
    x = math.cos(deg2rad(angle))
    y = math.sin(deg2rad(angle))
    return x, y


angle = 360 / sides
g.startPath()
g.setFillColor("red")

# curr_x = 0
# curr_y = 0
# curr_angle = 0

for i in range(sides + 1):
    dx, dy = calc(angle * i)
    g.moveTo(dx * len, dy * len)
    # curr_angle += angle
    # dx,dy = calc(curr_angle)
    # curr_x = dx*100
    # curr_y = dy*100
g.fillPath()

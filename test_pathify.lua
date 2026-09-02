local MathSvgPathify = require("math_svg_pathify")
local input = [[<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><text x="0" y="0" font-family="cmex10" font-size="1px" transform="matrix(32,0,0,32,100,50)" fill="rgb(0,0,0)" fill-opacity="1" style="white-space: pre;">&#80;</text></svg>]]
local out = MathSvgPathify.convert(input)
print("OUT:", out)

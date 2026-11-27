## 两种分解的关系

全响应可以按两种方式分解：

$$y(t) = \underbrace{\sum_{i=1}^{n} C_i e^{\lambda_i t}}_{\text{自由响应}} + \underbrace{y_p(t)}_{\text{强迫响应}}$$

也可以按零输入与零状态分解：

$$y(t) = y_{zi}(t) + y_{zs}(t) = \underbrace{\sum_{i} (C_{zi,i} + C_{zs,i}) e^{\lambda_i t}}_{\text{自由响应}} + \underbrace{y_p(t)}_{\text{强迫响应}}$$

经典法与状态法的对应关系写成：

$$y(t) = \underbrace{\text{自由响应} + \text{强迫响应}}_{\text{经典法（齐次解+特解）}} = \underbrace{\text{零输入响应} + \text{零状态响应}}_{\text{按初始状态分解}}$$

其中 $C_i = C_{zi,i} + C_{zs,i}$，自由响应包含零输入响应与零状态响应中的自然分量。

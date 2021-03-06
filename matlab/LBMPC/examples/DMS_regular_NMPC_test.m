%
clearvars;
% regular NMPC direct multiple shooting for Moore-Greitzer comperssor model
addpath('../utilities');
addpath('../models/'); 
addpath('../functions/'); 

import casadi.*

% Time horizon
T = 5.0;
% Control discretization
N = 50; % number of control intervals

n = 4; m = 1;
% eqilibilium point
x_eq = [0.500000000000000;1.68750000000000;1.15470000000000;0];
u_eq = 1.15470000000000;
x_init = [0.150000000000000;1.28750000000000;1.15470000000000;0];

% Constraints of the compressor model
mflow_min=0; mflow_max=1;
prise_min=1.1875; prise_max=2.1875;
throttle_min=0.1547; throttle_max=2.1547;
throttle_rate_min=-20; throttle_rate_max=20;
u_min=0.1547;u_max=2.1547;

umax = u_max; umin = u_min;
xmax = [mflow_max; prise_max; throttle_max; throttle_rate_max]; 
xmin = [mflow_min; prise_min; throttle_min; throttle_rate_min];

% Declare model variables
x1 = SX.sym('x1');
x2 = SX.sym('x2');
x3 = SX.sym('x3');
x4 = SX.sym('x4');
x = [x1; x2; x3; x4];
u = SX.sym('u');

% Model equations
xdot = [-x2+1+3*(x1/2)-(x1^3/2);...       % mass flow rate 
        (x1+1-x3*sqrt(x2));...            % pressure rise rate 
        x4;...                                % throttle opening rate
        -1000*x3-2*sqrt(500)*x4+1000*u];    % throttle opening accelerat

% Objective term
L = (x1)^2 + (x2)^2 + (x3)^2 + (x4)^2  + (u)^2;

% Formulate discrete time dynamics
if false
   % CVODES from the SUNDIALS suite
   dae = struct('x',x,'p',u,'ode',xdot,'quad',L);
   opts = struct('tf',T/N);
   F = integrator('F', 'cvodes', dae, opts);
else
   % Fixed step Runge-Kutta 4 integrator
   M = 4; % RK4 steps per interval
   DT = T/N/M;
   f = Function('f', {x, u}, {xdot, L});
   X0 = MX.sym('X0', n);
   U = MX.sym('U');
   X = X0;
   Q = 0;
   for j=1:M
       [k1, k1_q] = f(X, U);
       [k2, k2_q] = f(X + DT/2 * k1, U);
       [k3, k3_q] = f(X + DT/2 * k2, U);
       [k4, k4_q] = f(X + DT * k3, U);
       X=X+DT/6*(k1 +2*k2 +2*k3 +k4);
       Q = Q + DT/6*(k1_q + 2*k2_q + 2*k3_q + k4_q);
    end
    F = Function('F', {X0, U}, {X, Q}, {'x0','p'}, {'xf', 'qf'});
end


% Control discretization
N = 25; % number of control intervals
h = T/N;

% Start with an empty NLP
w={};
w0 = [];
lbw = [];
ubw = [];
J = 0;
g={};
lbg = [];
ubg = [];

% "Lift" initial conditions
Xk = MX.sym('X0', n);
w = [w(:)', {Xk}];
lbw = [lbw; x_init];
ubw = [ubw; x_init];
w0 = [w0; x_init];

% Formulate the NLP
for k=0:N-1
    % New NLP variable for the control
    Uk = MX.sym(['U_' num2str(k)]);
    w = [w(:)', {Uk}];
    lbw = [lbw; -inf];
    ubw = [ubw;  +inf];
    w0 = [w0;  x_init(3)];
    
    % Integrate till the end of the interval
    Fk = F('x0', Xk, 'p', Uk);
    Xk_end = Fk.xf;
    J=J+Fk.qf;
    
    % New NLP variable for state at end of interval
    Xk = MX.sym(['X_' num2str(k+1)], n);
    w = [w(:)', {Xk}];
    lbw = [lbw; xmin];
    ubw = [ubw;  xmax];
    w0 = [w0; zeros(n,1)];

    % Add equality constraint
    g = [g(:)', {Xk_end-Xk}];
    lbg = [lbg; zeros(n,1)];
    ubg = [ubg; zeros(n,1)];
end

% Create an NLP solver
prob = struct('f', J, 'x', vertcat(w{:}), 'g', vertcat(g{:}));
solver = nlpsol('solver', 'ipopt', prob);

% Solve the NLP
sol = solver('x0', w0, 'lbx', lbw, 'ubx', ubw,...
            'lbg', lbg, 'ubg', ubg);
w_opt = full(sol.x);

% Plot the solution
x1_opt = w_opt(1:(m+n):end);
x2_opt = w_opt(2:(m+n):end);
x3_opt = w_opt(3:(m+n):end);
x4_opt = w_opt(4:(m+n):end);
u_opt = w_opt(5:(m+n):end);
tgrid = linspace(0, T, N+1);
plotRESPONSE([x1_opt';x2_opt';x3_opt';x4_opt'; [u_eq; u_opt]'],tgrid,n,m);

clearvars; clc; 
addpath('../functions/');
addpath('../models/');
addpath('../utilities/');
%% INIT CONTROLLER DESIGN
syms u ... % control input
    x1 ... % mass flow
    x2 ... % pressure rise
    x3 ... % throttle opening
    x4 ... % throttle opening rate
    ;
wn=sqrt(1000); % resonant frequency
zeta=1/sqrt(2); % damping coefficient
beta=1; % constant >0
x2_c=0; % pressure constant
%% Constraints
mflow_min=0; mflow_max=1;
prise_min=1.1875; prise_max=2.1875;
throttle_min=0.1547; throttle_max=2.1547;
throttle_rate_min=-20; throttle_rate_max=20;
u_min=0.1547;u_max=2.1547;
%% Continous time state-space model of the Moore-Greitzer compressor model

f1 = -x2+x2_c+1+3*(x1/2)-(x1^3/2); % mass flow rate
f2 = (x1+1-x3*sqrt(x2))/(beta^2); % pressure rise rate
f3 = x4; % throttle opening rate
f4 = -wn^2*x3-2*zeta*wn*x4+wn^2*u; % throttle opening acceleration

%% Linearisation around the equilibrium [0.5 1.6875 1.1547 0]'

A = jacobian([f1,f2, f3, f4], [x1, x2, x3, x4]);
B = jacobian([f1,f2, f3, f4], [u]);

% equilibrium params
x1 = 0.5;
x2 = 1.6875;
x3 = 1.1547;
x4 = 0;
equili = [x1 x2 x3 x4];
init_cond = [x1-0.35, x2-0.4, x3, 0];  % init condition
% print the matrices in the cmd line
A = eval(A);
B = eval(B);
% C = [A(1, :); A(2,:)] % choose f1 and f2 as outputs 
C = eye(4);
D = zeros(4,1);
n=size(A,2);

% Visualise the poles and zeros of the continuous system
[b,a]=ss2tf(A,B,C,D);
sys = tf([b(1,:)],[a]);
% sys2 = tf([b(2,:)],[a]);
% figure;
% pzmap(sys);
% grid on;
% pzmap(sys2);
%% Exact discretisation

dT = 0.01; % sampling time

Ad = expm(A*dT);
Bd = (Ad-eye(n))*inv(A)*B;
Cd=C;
Dd=D;
Td=dT;
Ts=dT;
e = eig(Ad);
figure;
sys = idss(Ad,Bd,Cd,Dd,'Ts',dT);
pzmap(sys);

%% System stabilisation /w feedback matrix K to place poles near Re(p_old) inside unit circle
switch dT
    case 0.05
        p=[0.13, 0.16, 0.9, 0.95]; % dT=0.05
    case 0.02
        p=[0.55, 0.6, 0.9, 0.95]; % dT=0.02
    case 0.01
        p=[0.75, 0.78, 0.98, 0.99]; % dT=0.01
end

[K,prec,message] = place(Ad,Bd,p) %nominal feedback matrix
Kstabil=-K;

AK = Ad+Bd*Kstabil;
e = eig(AK);

Q = eye(4); R=1;
P = dare(AK,Bd,Q,R);
Klqr= -dlqr(Ad,Bd,Q,R);
figure;
sys = idss(AK,zeros(4,1),Cd,Dd,'Ts',dT);
pzmap(sys);


%% TRACKING piecewise constant REFERENCE MPC example

% clearvars;

%% Parameters
% Horizon length
N=20;
% Simulation length (iterations)
iterations = 10/dT;

%% Discrete time nominal model of the non-square LTI system for tracking
A = Ad;
B = Bd;
C = Cd;
% D = [0;0;0;0];
n = size(A,1);
m = size(B,2);
o = size(C,1);

% The initial conditions
x_eq_init = [-0.35;...
    -0.4;...
    0.0;...
    0.0];
%setpoint
x_eq_ref = [0.0;...
      0.0;...
      0.0;...
      0.0];
x_w = [0.5;...
    1.6875;...
    1.1547;...
    0.0];
r0 = x_w(3);
Q = eye(n);
R = eye(m);
%%
%==========================================================================
% Define a nominal feedback policy K and corresponding terminal cost
% 'baseline' stabilizing feedback law
% K = -dlqr(A, B, Q, R);

%%
% Kstable=[+3.0741 2.0957 0.1197 -0.0090]; % K stabilising gain from the papers
% Kstabil=-[3.0742   -2.0958   -0.1194    0.0089];
u0 = zeros(m*N,1); % start inputs
theta0 = zeros(m,1); % start param values
opt_var = [u0; theta0];
%% Start simulation
sysHistory = [x_eq_init;u0(1:m,1)];
sysHistoryL=sysHistory;
sysHistoryO=sysHistory;
sysHistoryO2=sysHistory;
art_refHistory =  0;
true_refHistory = x_eq_ref;
options = optimoptions('fmincon','Algorithm','sqp','Display','notify');
x = x_w+x_eq_init; % true sistem init state
% init states from models used in MPC
xl=x_eq_init;
xo=x_eq_init;
xo2=x_eq_init;
% init data form estimation
data.X=zeros(3,1);
data.Y=zeros(4,1);
q=iterations/20; % moving window of q datapoints 
data2=zeros(8,q); % data2(8,1)=1;
tic;
for k = 1:(iterations)      
    %%
    fprintf('iteration no. %d/%d \n',k,iterations);
    c=0;
    % Implement first optimal control move and update plant states.
    [x_k1, u] = transitionTrue(x,c,x_w,r0,Kstabil,dT); % true model
    [xl_k1, ul] = transitionNominal(xl,c,Kstabil); % linear model
    [xo,uo]=transitionLearned(xo,c,Kstabil,data); % learned model
    [xo2,uo2]=transitionLearned2(xo2,c,Kstabil,data2); % learned model2
    %%%%%%%%%%%%%% DATA GENERATION %%%%%%%%%%%%%
    X=[x(1:2)-x_w(1:2); u-r0]; %[δphi;δpsi;δu]
    switch dT
        case 0.01
            Y=((x_k1-x_w)-(A*(x-x_w)+B*(u-r0))); %[δx_true-δx_nominal]
        otherwise
            Y=-((x_k1-x_w)-(A*(x-x_w)+B*(u-r0))); %[δx_true-δx_nominal]
    end
    
    data=update_data(X,Y,q,k,data);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % data acquisition 
    X2=[x(1:2)-x_w(1:2); u-r0]; %[δx1;δx2;δu]
    Y2=x_k1-(x_w+A*(x-x_w)+ B*(u-r0)); %[δx_true-δx_nominal]
    data2 = get_data(X2,Y2,q,k,data2); % update data     
   
    % shift the output so that it's from the working point perspective
    % setpoint being [0;0;0;0]
    his = [x-x_w; u-r0]; % c: decision var; u-r0: delta u;
    hisO=[xo;uo];
    hisO2=[xo2;uo2];
    hisL=[xl;ul];
    
    % Save plant states for display.
    sysHistory = [sysHistory his]; %#ok<*AGROW>
    sysHistoryL = [sysHistoryL hisL]; %#ok<*AGROW>
    sysHistoryO = [sysHistoryO hisO]; %#ok<*AGROW>
    sysHistoryO2 = [sysHistoryO2 hisO2]; %#ok<*AGROW>
    x=x_k1;
    xl=xl_k1;
end
toc


%% PLOT
figure;
subplot(n+m,1,1);
plot(0:iterations,sysHistory(1,:),'Linewidth',1.5); hold on;
plot(0:iterations,sysHistoryL(1,:),'Linewidth',1.5,'LineStyle','--'); hold on;
plot(0:iterations,sysHistoryO(1,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(0:iterations,sysHistoryO2(1,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('iterations');
ylabel('x1');
title('mass flow');
subplot(n+m,1,2);
plot(0:iterations,sysHistory(2,:),'Linewidth',1.5); hold on;
plot(0:iterations,sysHistoryL(2,:),'Linewidth',1.5,'LineStyle','--'); hold on;
plot(0:iterations,sysHistoryO(2,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(0:iterations,sysHistoryO2(2,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('iterations');
ylabel('x2');
title('pressure rise');
subplot(n+m,1,3);
plot(0:iterations,sysHistory(3,:),'Linewidth',1.5); hold on;
plot(0:iterations,sysHistoryL(3,:),'Linewidth',1.5,'LineStyle','--'); hold on;
plot(0:iterations,sysHistoryO(3,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(0:iterations,sysHistoryO2(3,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('iterations');
ylabel('x3');
title('throttle');
subplot(n+m,1,4);
plot(0:iterations,sysHistory(4,:),'Linewidth',1.5); hold on;
plot(0:iterations,sysHistoryL(4,:),'Linewidth',1.5,'LineStyle','--'); hold on;
plot(0:iterations,sysHistoryO(4,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(0:iterations,sysHistoryO2(4,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('iterations');
ylabel('x4');
title('throttle rate');
subplot(n+m,1,5);
plot(0:iterations,sysHistory(5,:),'Linewidth',1.5); hold on;
plot(0:iterations,sysHistoryL(5,:),'Linewidth',1.5,'LineStyle','--'); hold on;
plot(0:iterations,sysHistoryO(5,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(0:iterations,sysHistoryO2(5,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('iterations');
ylabel('u');
title('Sys input');
legend({'True system', 'Linear system', 'Learned true system', 'Learned true system2'});


figure;
plot(sysHistory(1,:),sysHistory(2,:),'Linewidth',1.5,'LineStyle','-'); hold on;
plot(sysHistoryL(1,:),sysHistoryL(2,:),'Linewidth',1.5,'LineStyle','--');  hold on;
plot(sysHistoryO(1,:),sysHistoryO(2,:),'Linewidth',1.5,'LineStyle','-.','Color','g');
plot(sysHistoryO2(1,:),sysHistoryO2(2,:),'Linewidth',1.5,'Color','r','LineStyle','--');
grid on
xlabel('x1');
ylabel('x2');
title('State space');


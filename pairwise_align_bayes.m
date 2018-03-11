function out = pairwise_align_bayes(f1, f2, time, mcmcopts)
if nargin < 4
    mcmcopts.iter = 2e4;
    mcmcopts.burnin = min(5e3,mcmcopts.iter/2);
    mcmcopts.alpha0 = 0.1;
    mcmcopts.beta0 = 0.1;
    tmp.betas = [0.5,0.5,0.005,0.0001];
    tmp.probs = [0.1,0.1,0.7,0.1];
    mcmcopts.zpcn = tmp;
    mcmcopts.propvar = 1;
    mcmcopts.initcoef = repelem(0, 20);
    mcmcopts.npoints = 200;
    mcmcopts.extrainfo = true;
end

if (length(f1) ~= length(f2))
    error('Length of f1 and f2 must be equal')
end
if (length(f1) ~= length(time))
    error('Length of f1 and time must be equal')
end
if (length(mcmcopts.zpcn.betas) ~= length(mcmcopts.zpcn.probs))
    error('In zpcn, betas must equal length of probs')
end
if (mod(length(mcmcopts.initcoef), 2) ~= 0)
    error('Length of mcmcopts.initcoef must be even')
end

% Number of sig figs to report in gamma_mat
SIG_GAM = 13;
iter = mcmcopts.iter;

% for now, back to struct format of Yi's software
f1.x = time;
f1.y = f1;
f2.x = tie;
f2.y = f2;

% normalize timet to [0,1]
% ([a,b] - a) / (b-a) = [0,1]
rangex = range(f1.x);
f1.x = (f1.x-rangex(1))./(rangex(2)-rangex(1));
f2.x = (f2.x-rangex(1))./(rangex(2)-rangex(1));

% parameter settings
pw_sim_global_burnin = mcmcopts.burnin;
valid_index = pw_sim_global_burnin:iter;
pw_sim_global_Mg = length(mcmcopts.initcoef)/2;
g_coef_ini = mcmcopts.initcoef;
numSimPoints = mcmcopts.npoints;
pw_sim_global_domain_par = linspace(0,1,numSimPoints);
g_basis = basis_fourier(pw_sim_global_domain_par, pw_sim_global_Mg, 1);
sigma1_ini = 1;
pw_sim_global_sigma_g = mcmcopts.propvar;

    function result = propose_g_coef(g_coef_curr)
        pCN_beta = zpcn.betas;
        pCN_prob = zpcn.probs;
        probm = [0, cumsum(pCN_prob)];
        z = rand;
        for i = 1:length(pCN_beta)
            if (z <= probm(i+1) && z > probm(i))
                g_coef_new = normrnd(0, pw_sim_global_sigma_g / repelem(1:pw_sim_global_Mg,2), 1, pw_sim_global_Mg * 2);
                result.prop = sqrt(1-pCN_beta(i)^2) * g_coef_curr + pCN_beta(i) * g_coef_new;
                result.ind = i;
            end
        end
    end

% srsf transformation
q1 = f_Q(f1);
q2 = f_Q(f2);

% init chain
obs_domain = q1.x;

tmp = f_exp1(f_basistofunction(g_basis.x,0,g_coef_ini,g_basis, false));
if (min(tmp.y)<0)
    error("Invalid initial value of g")
end

% result objects
result.g_coef = zeros(iter,length(g_coef_ini));
result.sigma1 = zeros(1,iter);
result.logl = zeros(1,iter);
result.SSE = rep(1,iter);
result.accept = rep(1,iter);
result.accept_betas = rep(1,iter);

% init
g_coef_curr = g_coef_ini;
sigma1_curr = sigma1_ini;
SSE_curr = f_SSEg_pw(f_basistofunction(g_basis.x,0,g_coef_ini,g_basis,false),q1,q2);
logl_curr = f_logl_pw(f_basistofunction(g_basis.x,0,g_coef_ini,g_basis,false),sigma1_ini^2,q1,q2,SSE_curr);

result.g_coef(:,1) = g_coef_ini;
result.sigma1(1) = sigma1_ini;
result.SSE(1) = SSE_curr;
result.logl(1) = logl_curr;

% update the chain for iter-1 times
for m = 2:iter
    % update g
    a = f_updateg_pw(g_coef_curr, g_basis, sigma1_curr^2, q1, q2, SSE_curr, propose_g_coef);
    g_coef_curr = a.g_coef;
    SSE_curr = a.SSE;
    logl_curr = a.logl;
    
    % update sigma1
    newshape = length(q1.x)/2 + alpha0;
    newscale = 1/2 * SSE_curr + beta0;
    sigma1_curr = sqrt(1/gamrnd(newshape,newscale));
    logl_curr = f_logl_pw(f_basistofunction(g_basis.x, 0, g_coef_curr, g_basis, false), sigma1_curr^2, q1, q2, SSE_curr);
    
    % save update to results
    result.g_coef(:,m) = g_coef_curr;
    result.sigma1(m) = sigma1_curr;
    result.SSE(m) = SSE_curr;
    if (mcmcopts.extrainfo)
        result.logl(m) = logl_curr;
        result.accept(m) = a.accept;
        result.accept_betas(m) = a.zpcnInd;
    end
end

% calculate posterior mean of psi
pw_sim_est_psi_matrix = zeros(length(pw_sim_global_domain_par), length(valid_index));
for k = 1:length(valid_index)
    g_temp = f_basistofunction(pw_sim_global_domain_par, 0, result.g_coef(:, valid_index(k)), g_basis, false);
    psi_temp = f_exp1(g_temp);
    pw_sim_est_psi_matrix(:,k) = psi_temp.y;
end

result_posterior_psi_simDomain = f_psimean(pw_sim_global_domain_par, pw_sim_est_psi_matrix);

% resample to same number of points as the input f1 and f2
result_posterior_psi = interp1(result_posterior_psi_simDomain.x, result_posterior_psi_simDomain.y, f1.x, 'linear', 'extrap');

% transform posterior mean of psi to gamma
result_posterior_gamma = f_phiinv(result_posterior_psi);
gam0 <- result_posterior_gamma.y;
result_posterior_gamma.y = norm_gam(gam0);

% warped f2
f2_warped = warp_f_gamma(f2.y, result_posterior_gamma.y, result_posterior_gamma.x);

if (mcmcopts.extrainfo)
    % matrix of posterior draws from gamma
    gamma_mat = pw_sim_est_psi_matrix;
    one_v = ones(1,size(pw_sim_est_psi_matrix,1));
    Dx = zeros(1,size(pw_sim_est_psi_matrix,2));
    Dy = Dx;
    gamma_stats = zeros(2,size(pw_sim_est_psi_matrix,2));
    for ii = 1:size(pw_sim_est_psi_matrix,2)
        tmp = interp1(pw_sim_global_domain_par, pw_sim_est_psi_matrix(:,ii), f1.x, 'linear', 'extrap');
        tmp1.x = pw_sim_global_domain_par;
        tmp1.y = tmp;
        tmp = f_phiinv(tmp1);
        gamma_mat(:,ii) = round(norm_gam(tmp.y),SIG_GAM);
        v = inv_exp_map(one_v, pw_sim_est_psi_matrix(:,ii));
        Dx(ii) = sqrt(trapz(pw_sim_global_domain_par, v.^2));
        q2warp = warp_q_gamma(q2.y, gamma_mat(:,ii), q2.x);
        Dy(ii) = sqrt(trapz(q2.x,(q1.y-q2warp).^2));
        gamma_stats(:,ii) = statsFun(gamma_mat(:,ii));
    end
end

% return object
out.f2_warped = f2_warped;
out.gamma = result_posterior_gamma;
out.g_coef = result.g_coef;
out.psi = result_posterior_psi;
out.sigma1 = result.sigma1;

if (mcmcopts.extrainfo)
    out.accept = result.accept(2:end);
    out.betas_ind = result.accept_betas(2:end);
    out.logl = result.logl;
    out.gamma_mat = gamma_mat;
    out.gamma_stats = gamma_stats;
    out.xdist = Dx;
    out.ydist = Dy;
end
end

function out = statsFun(vec)
a = quantile(vec,0.025);
b = quantile(vec,0.975);
out = [a,b];
end

function [x,y] = f_exp1(g)
x = g.x;
y = bcalcY(f_L2norm(g), g.y);
end

function [x,yy] = f_exp1inv(psi)
x = psi.x;
y = psi.y;

[x,ia,~] = unique(x);
[x, ia1] = sort(x);
y = y(ia);
y = y(ia1);
inner = round(trapzCpp(x,y), 10);

if ((inner < 1.001) && (inner >= 1))
    inner = 1;
end
if ((inner <= -1) && (inner > -1.001))
    inner = -1;
end
if ((inner < (-1)) || (inner > 1))
    fprintf("exp1inv: can't calculate the acos of: %f\n", inner);
end

theta = acos(inner);
yy = theta / sin(theta) .* (y - repelem(inner,length(y)));

if (theta==0)
    yy = zeros(1,length(x));
end

end

% function for calculating the next MCMC sample given current state
function [g_coef, logl, SSE, accept, zpcnInd] = f_updateg_pw(g_coef_curr,g_basis,var1_curr,q1,q2,SSE_curr,propose_g_coef)
g_coef_prop = propose_g_coef(g_coef_curr);

tst = f_exp1(f_basistofunction(g_basis.x,0,g_coef_prop.prop,g_basis, false));
while (min(tst.x)<0)
    g_coef_prop = propose_g_coef(g_coef_curr);
    tst = f_exp1(f_basistofunction(g_basis.x,0,g_coef_prop.prop,g_basis, false));
end

if (SSE_curr == 0)
    SSE_curr = f_SSEg_pw(f_basistofunction(g_basis.x,0,g_coef_curr,g_basis, false), q1, q2);
end

SSE_prop = f_SSEg_pw(f_basistofunction(g_basis.x,0,g_coef_prop,g_basis,false), q1, q2);

logl_curr = f_logl_pw(f_basistofunction(g_basis.x,0,g_coef_curr,g_basis,false), var1_curr, q1, q2, SSE_curr);

logl_prop = f_logl_pw(f_basistofunction(g_basis.x,0,g_coef_prop,g_basis,false), var1_curr, q1, q2, SSE_prop);

ratio = min(1, exp(logl_prop-logl_curr));

u = rand;
if (u <= ratio)
    g_coef = g_coef_prop.prop;
    logl = logl_prop;
    SSE = SSE_prop;
    accept = true;
    zpcnInd = g_coef_prop.ind;
end

if (u > ratio)
    g_coef = g_coef_curr;
    logl = logl_curr;
    SSE = SSE_curr;
    accept = false;
    zpcnInd = g_coef_prop.ind;
end
end

%##########################################################################
% For pairwise registration, evaluate the loglikelihood of g, given q1 and
% q2
% g, q1, q2 are all given in the form of struct.x and struct.y
% var1: model variance
% SSEg: if not provided, than re-calculate
% returns a numeric value which is logl(g|q1,q2), see Eq 10 of JCGS
%##########################################################################
% SSEg: sum of sq error= sum over ti of { q1(ti)-{q2,g}(ti) }^2
% (Eq 11 of JCGS)
function out = f_SSEg_pw(g, q1, q2)
obs_domain = q1.x;
exp1g_temp = f_predictfunction(f_exp1(g), obs_domain, 0);
pt = [0, bcuL2norm2(obs_domain, exp1g_temp.y)];
tmp = f_predictfunction(q2, pt, 0);
vec = (q1.y - tmp.y .* exp1g_temp.y);
out = sum(vec);
end

function out = f_logl_pw(g, q1, q2, var1, SSEg)
if (SSEg == 0)
    SSEg = f_SSEg_pw(g, q1, q2);
end
n = length(q1.y);
out = n * log(1/sqrt(2*pi)) - n * log(sqrt(var1)) - SSEg / (2 * var1);
end

%##########################################################################
% calculate Q(f), Qinv(q)
% f,q: function in the form of list$x, list$y
% fini: f(0)
% returns Q(f),Qinv(q), function in the form of struct.x, struct.y
%##########################################################################
function out = f_Q(f)
d = f_predictfunction(f, f.x, 1);
out.x = f.x;
out.y = sign(d.y) * sqrt(abs(d.y));
end

function out = f_Qinv(q, fini)
result = zeros(1,length(q.x));
for i = 1:length(result)
    y = q.y(1:i);
    x = q.x(1:i);
    [x,ia,~] = unique(x);
    [x, ia1] = sort(x);
    y = y(ia);
    y = y(ia1);
    result(i) = trapzCpp(x,(y*abs(y)));
end
result = result + fini;
result(1) = fini;
out.x = q.x;
out.y = result;
end

%##########################################################################
% Extrapolate a function given by a discrete vector
% f: function in the form of list$x, list$y
% at: t values for which f(t) is returned
% deriv: can calculate derivative
% method: smoothing method: 'linear' (default), 'cubic'
% returns: $y==f(at), $x==at
%##########################################################################
function out = f_predictfunction(f, at, deriv)
if (deriv == 0)
    result = interp1(f.x,f.y,at,'linear','extrap');
    out.x = at;
    out.y = result;
end

if (deriv == 1)
    fmod = interp1(f.x,f.y,at,'linear','extrap');
    diffy1 = [0, diff(fmod)];
    diffy2 = [diff(fmod), 0];
    diffx1 = [0, diff(at)];
    diffx2 = [diff(at), 0];
    
    
    out.x = at;
    out.y = (diffy2 + diffy1) / (diffx2 + diffx1);
end
end

%##########################################################################
% calculate L2 norm of a function, using trapezoid rule for integration
% f:function in the form of list$x, list$y
% returns ||f||, a numeric value
%##########################################################################
function out = f_L2norm(f)
out = border_l2norm(f.x,f.y);
end

%##########################################################################
% Different basis functions b_i()
% f.domain: grid on which b_i() is to be returned
% numBasis: numeric value, number of basis functions used
% (note: #basis = #coef/2 for Fourier basis)
% fourier.p: period of the Fourier basis used
% returns a struct:
%     matrix: with nrow=length(t) and ncol=numBasis (or numBasis*2 for
%     Fourier)
%     x: f.domain
%##########################################################################
function out = basis_fourier(f_domain, numBasis, fourier_p)
result = zeros(length(f_domain), 2*numBasis);
for i = 1:(2*numBasis)
    j = ceil(i/2);
    if (mod(i,2) == 1)
        result(:,i) = sqrt(2) * sin(2*j*pi*f_domain./fourier_p);
    end
    if (mod(i,2) == 0)
        result(:,i) = sqrt(2) * cos(2*j*pi*f_domain./fourier_p);
    end
    out.x = f_domain;
    out.matrix = result;
end
end

%##########################################################################
% Given the coefficients of basis functions, returns the actual function on
% a grid
% f.domain: numeric vector, grid of the actual function to return
% coefconst: leading constant term
% coef: numeric vector, coefficients of the basis functions
%       Note: if #coef < #basis functions, only the first %coef basis
%             functions will be used
% basis: in the form of list$x, list$matrix
% plotf: if true, show a plot of the function generated
% returns the generated function in the form of struct.x=f.domain, struct.y
%##########################################################################
function result = f_basistofunction(f_domain, coefconst, coef, basis, plotf)
if (size(basis.matrix,2) < length(coef))
    error('In f_basistofunction, #coeffients exceeds #basis functions.')
end
result.x = basis.x;
result.y = basis.matrix(:,(1:length(coef))) * coef + coefconst;

result = f_predictfunction(result, f_domain, 0);
if (plotf)
    plot(result.x,result.y)
end
end

%##########################################################################
% Calculate exp_psi(g), expinv_psi(psi2)
% g, psi: function in the form of list$x, list$y
% returns exp_psi(g) or expinv_psi(psi2), function in the form of struct.x,
% struct.y
%##########################################################################
function out = f_exppsi(psi, g)
area = round(f_L2norm(g), 10);
y = cos(area) * psi.y + sin(area)/area * g.y;
if (area == 0)
    y = psi.y;
end
out.x = g.x;
out.y = y;
end

function out = f_exppsiinv(psi, psi2)
x = psi.x;
[x,ia,~] = unique(x);
[x, ia1] = sort(x);
y = psi.y(ia);
y = y(ia1);
inner = round(trapz(x,y*y),10);
if ((inner < 1.001) && (inner >= 1))
    inner = 1;
end
if ((inner < 1.05) && (inner >= 1.001))
    fprintf("exppsiinv: caution! acos of: %d is set to 1...\n", inner);
    inner = 1;
end
if ((inner <= -1) && (inner > -1.001))
    inner = -1;
end
if ((inner <= -1.001) && (inner > -1.05))
    fprintf("exppsiinv: caution! acos of: %d is set to -1...\n", inner);
    inner = -1;
end
if ((inner < (-1)) || (inner > 1))
    fprintf("exppsiinv: can't calculate the acos of: %d", inner);
end
theta = acos(inner);
yy = theta/sin(theta) * ((psi2.y) - inner * (psi.y));
if (theta == 0)
    yy = zeros(1,length(x));
end
out.x = x;
out.y = yy;
end

%##########################################################################
% Calculate Karcher mean/median with Alg1/Alg2 in (Kurtek,2014)
% x: vector of length = length(domain of the psi's)
% y: M columns, each of length = length(x)
% e1, e2: small positive constants
% method: 'ext' = extrinsic, 'int' = intrinsic
% returns posterier mean/median of M psi's (of form .x, .y)
%##########################################################################
function out = f_psimean(x, y)
rmy = mean(y,2);
tmp.x = x;
tmp.y = rmy;
result = rmy / f_L2norm(tmp);
out.x = x;
out. y = result;
end

%##########################################################################
% calculate phi(gamma), phiinv(psi)
% gamma, psi: function in the form of struct.x, struct.y
% returns phi(gamma) or phiinv(psi), function in the form of struct.x,
% struct.y
%##########################################################################
function result = f_phi(gamma)
f_domain = gamma.x;
k = f_predictfunction(gamma, f_domain, 1);
k = k.y;
if (isempty(find(k < 0, 1)) ~= 0)
    idx = k < 0;
    k(idx) = 0;
end
result.x = f_domain;
result.y = sqrt(k);
if (f_L2norm(result) >= (1.01) || f_L2norm(result) <= (0.99))
    result.y = result.y / f_L2norm(result);
end
end
% the function returned by phi(gamma) = psi is always positive and has L2norm 1

function out = f_phiinv(psi)
f_domain = psi.x;
result = [0, bcuL2norm2(f_domain, psi.y)];
out.x = f_domain;
out.y = result;
end

% Normalize gamma to [0,1]
function gam = norm_gam(gam)
gam = (gam-gam(1))./(gam(end)-gam(1));
end

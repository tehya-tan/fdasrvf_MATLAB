classdef fdawarp
    % fdawarp elastic fda functional class
    %   fdawarp object contains the ability to align and plot functional
    %   data and is required for follow on analysis
    
    properties
        f      % (M,N): matrix defining N functions of M samples
        time   % time vector of length M
        fn     % aligned functions
        qn     % aligned srvfs
        q0     % initial srvfs
        fmean  % function mean
        mqn    % mean srvf
        gam    % warping functions
        psi    % srvf of warping functions
        stats  % alignment statistics
        qun    % cost function
        lambda % lambda
        method % optimization method
        gamI   % invserse warping function
        rsamps % random samples
    end
    
    methods
        function obj = fdawarp(f,time)
            %fdawarp Construct an instance of this fdawarp
            % Input:
            %   f: (M,N): matrix defining N functions of M samples
            %   time: time vector of length M
            
            % check dimension of time
            a = size(time,1);
            if a == 1
                time = time';
            end
            
            obj.f = f;
            obj.time = time;
        end
        
        function obj = time_warping(obj,lambda,option)
            % time_warping Group-wise function alignment
            % -------------------------------------------------------------------------
            % This function aligns a collection of functions using the elastic square-root
            % slope (srsf) framework.
            %
            % Usage:  out = time_warping(f,t)
            %         out = time_warping(f,t,lambda)
            %         out = time_warping(f,t,lambda,option)
            %
            % Input:
            % f (M,N): matrix defining N functions of M samples
            % t : time vector of length M
            % lambda: regularization parameter
            %
            % default options
            % option.parallel = 0; % turns offs MATLAB parallel processing (need
            % parallel processing toolbox)
            % option.closepool = 0; % determines wether to close matlabpool
            % option.smooth = 0; % smooth data using standard box filter
            % option.sparam = 25; % number of times to run filter
            % option.showplot = 1; % turns on and off plotting
            % option.method = 'DP1'; % optimization method (DP, DP2, SIMUL, RBFGS)
            % option.w = 0.0; % BFGS weight
            % option.MaxItr = 20;  % maximum iterations
            %
            % Output:
            % fdawarp object
            if nargin < 2
                lambda = 0;
                option.parallel = 0;
                option.closepool = 0;
                option.smooth = 0;
                option.sparam = 25;
                option.method = 'DP1';
                option.w = 0.0;
                option.MaxItr = 20;
            elseif nargin < 3
                option.parallel = 0;
                option.closepool = 0;
                option.smooth = 0;
                option.sparam = 25;
                option.method = 'DP1';
                option.w = 0.0;
                option.MaxItr = 20;
            end
            
            % time warping on a set of functions
            if option.parallel == 1
                if isempty(gcp('nocreate'))
                    % prompt user for number threads to use
                    nThreads = input('Enter number of threads to use: ');
                    if nThreads > 1
                        parpool(nThreads);
                    elseif nThreads > 12 % check if the maximum allowable number of threads is exceeded
                        while (nThreads > 12) % wait until user figures it out
                            fprintf('Maximum number of threads allowed is 12\n Enter a number between 1 and 12\n');
                            nThreads = input('Enter number of threads to use: ');
                        end
                        if nThreads > 1
                            parpool(nThreads);
                        end
                    end
                end
            end
            %% Parameters
            
            fprintf('\n lambda = %5.1f \n', lambda);
            
            binsize = mean(diff(obj.time));
            [M, N] = size(obj.f);
            
            f1 = obj.f;
            if option.smooth == 1
                f1 = smooth_data(f1, option.sparam);
            end
            
            %% Compute the q-function of the plot
            q = f_to_srvf(obj.f,obj.time);
            
            %% Set initial using the original f space
            fprintf('\nInitializing...\n');
            mnq = mean(q,2);
            dqq = sqrt(sum((q - mnq*ones(1,N)).^2,1));
            [~, min_ind] = min(dqq);
            mq = q(:,min_ind);
            mf = obj.f(:,min_ind);
            
            gam_o = zeros(N,size(q,1));
            if option.parallel == 1
                parfor k = 1:N
                    q_c = q(:,k,1); mq_c = mq;
                    gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                        mf(1), f1(1,k,1));
                end
            else
                for k = 1:N
                    q_c = q(:,k,1); mq_c = mq;
                    gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                        mf(1), f1(1,k,1));
                end
            end
            gamI_o = SqrtMeanInverse(gam_o);
            mf = warp_f_gamma(mf,gamI_o,obj.time);
            mq = f_to_srvf(mf,obj.time);
            
            %% Compute Mean
            fprintf('Computing Karcher mean of %d functions in SRVF space...\n',N);
            ds = inf;
            MaxItr = option.MaxItr;
            qun_o = zeros(1,MaxItr);
            f_temp = zeros(length(obj.time),N);
            q_temp = zeros(length(obj.time),N);
            for r = 1:MaxItr
                fprintf('updating step: r=%d\n', r);
                if r == MaxItr
                    fprintf('maximal number of iterations is reached. \n');
                end
                
                % Matching Step
                clear gam gam_dev;
                % use DP to find the optimal warping for each function w.r.t. the mean
                gam_o = zeros(N,size(q,1));
                gam_dev = zeros(N,size(q,1));
                if option.parallel == 1
                    parfor k = 1:N
                        q_c = q(:,k,1); mq_c = mq(:,r);
                        gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                            mf(1,r), f1(1,k,1));
                        gam_dev(k,:) = gradient(gam_o(k,:), 1/(M-1));
                        f_temp(:,k) = warp_f_gamma(f1(:,k,1),gam_o(k,:),obj.time);
                        q_temp(:,k) = f_to_srvf(f_temp(:,k),obj.time);
                    end
                else
                    for k = 1:N
                        q_c = q(:,k,1); mq_c = mq(:,r);
                        gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                            mf(1,r), f1(1,k,1));
                        gam_dev(k,:) = gradient(gam_o(k,:), 1/(M-1));
                        f_temp(:,k) = warp_f_gamma(f1(:,k,1),gam_o(k,:),obj.time);
                        q_temp(:,k) = f_to_srvf(f_temp(:,k),obj.time);
                    end
                end
                q(:,:,r+1) = q_temp;
                f1(:,:,r+1) = f_temp;
                
                ds(r+1) = sum(simps(obj.time, (mq(:,r)*ones(1,N)-q(:,:,r+1)).^2)) + ...
                    lambda*sum(simps(obj.time, (1-sqrt(gam_dev')).^2));
                
                % Minimization Step
                % compute the mean of the matched function
                mq(:,r+1) = mean(q(:,:,r+1),2);
                mf(:,r+1) = mean(f1(:,:,r+1),2);
                
                qun_o(r) = norm(mq(:,r+1)-mq(:,r))/norm(mq(:,r));
                if qun_o(r) < 1e-2 || r >= MaxItr
                    break;
                end
            end
            
            % last step with centering of gam
            r = r+1;
            if option.parallel == 1
                parfor k = 1:N
                    q_c = q(:,k,1); mq_c = mq(:,r);
                    gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                        mf(1,r), f1(1,k,1));
                end
            else
                for k = 1:N
                    q_c = q(:,k,1); mq_c = mq(:,r);
                    gam_o(k,:) = optimum_reparam(mq_c,q_c,obj.time,lambda,option.method,option.w, ...
                        mf(1,r), f1(1,k,1));
                end
            end
            gamI_o = SqrtMeanInverse(gam_o);
            mq(:,r+1) = warp_q_gamma(mq(:,r),gamI_o,obj.time);
            for k = 1:N
                q(:,k,r+1) = warp_q_gamma(q(:,k,r),gamI_o,obj.time);
                f1(:,k,r+1) = warp_f_gamma(f1(:,k,r),gamI_o,obj.time);
                gam_o(k,:) = interp1(obj.time, gam_o(k,:), (obj.time(end)-obj.time(1)).*gamI_o + obj.time(1));
            end
            
            %% Aligned data & stats
            obj.fn = f1(:,:,r+1);
            obj.qn = q(:,:,r+1);
            obj.q0 = q(:,:,1);
            std_f0 = std(f1, 0, 2);
            std_fn = std(obj.fn, 0, 2);
            obj.mqn = mq(:,r+1);
            obj.fmean = mean(obj.f(1,:))+cumtrapz(obj.time,obj.mqn.*abs(obj.mqn));
            
            fgam = zeros(M,N);
            for ii = 1:N
                fgam(:,ii) = warp_f_gamma(obj.fmean,gam_o(ii,:),obj.time);
            end
            var_fgam = var(fgam,[],2);
            
            obj.stats.orig_var = trapz(obj.time,std_f0.^2);
            obj.stats.amp_var = trapz(obj.time,std_fn.^2);
            obj.stats.phase_var = trapz(obj.time,var_fgam);
            
            obj.gam = gam_o.';
            [~,fy] = gradient(obj.gam,binsize,binsize);
            obj.psi = sqrt(fy+eps);
            
            if option.parallel == 1 && option.closepool == 1
                if isempty(gcp('nocreate'))
                    delete(gcp('nocreate'))
                end
            end
            
            obj.qun = qun_o(1:r-1);
            obj.lambda = lambda;
            obj.method = option.method;
            obj.gamI = gamI_o;
            obj.rsamps = false;
        end
        
        function plot(obj)
            % plot plot functional alignment results
            % -------------------------------------------------------------------------
            % This function aligns a collection of functions using the elastic square-root
            % slope (srsf) framework.
            figure(1); clf;
            plot(obj.time, obj.f, 'linewidth', 1);
            title('Original data', 'fontsize', 16);
            
            if (~isempty(obj.gam))
                mean_f0 = mean(obj.f, 2);
                std_f0 = std(obj.f, 0, 2);
                mean_fn = mean(obj.fn, 2);
                std_fn = std(obj.fn, 0, 2);
                figure(2); clf;
                M = length(obj.time);
                plot((0:M-1)/(M-1), obj.gam, 'linewidth', 1);
                axis square;
                title('Warping functions', 'fontsize', 16);
                
                figure(3); clf;
                plot(obj.time, obj.fn, 'LineWidth',1);
                title(['Warped data, \lambda = ' num2str(obj.lambda)], 'fontsize', 16);
                
                figure(4); clf;
                plot(obj.time, mean_f0, 'b-', 'linewidth', 1); hold on;
                plot(obj.time, mean_f0+std_f0, 'r-', 'linewidth', 1);
                plot(obj.time, mean_f0-std_f0, 'g-', 'linewidth', 1);
                title('Original data: Mean \pm STD', 'fontsize', 16);
                
                figure(5); clf;
                plot(obj.time, mean_fn, 'b-', 'linewidth', 1); hold on;
                plot(obj.time, mean_fn+std_fn, 'r-', 'linewidth', 1);
                plot(obj.time, mean_fn-std_fn, 'g-', 'linewidth', 1);
                title(['Warped data, \lambda = ' num2str(obj.lambda) ': Mean \pm STD'], 'fontsize', 16);
                
                figure(6); clf;
                plot(obj.time, obj.fmean, 'g','LineWidth',1);
                title(['f_{mean}, \lambda = ' num2str(obj.lambda)], 'fontsize', 16);
            end
        end
        
    end
    
end
